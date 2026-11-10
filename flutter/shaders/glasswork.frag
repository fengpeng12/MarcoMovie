#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uRadius;
uniform float uScale;
uniform sampler2D uScene;
out vec4 fragColor;

vec4 sampleScene(vec2 point) {
    vec2 uv = clamp(point / uSize, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(uScene, uv);
}

// Glasswork refract.js uses a 12-tap spiral plus the center for its 2px blur.
vec3 blurred(vec2 point) {
    float radius = 2.0 * uScale;
    vec3 sum = sampleScene(point).rgb;
    float total = 1.0;
    for (int i = 0; i < 12; i++) {
        float d = radius * 2.2 * sqrt((float(i) + 0.5) / 12.0);
        float angle = float(i) * 2.39996;
        float weight = exp(-d*d / (2.0*radius*radius));
        sum += sampleScene(point + vec2(cos(angle), sin(angle))*d).rgb * weight;
        total += weight;
    }
    return sum / total;
}

float luminance(vec3 c) {
    vec3 low = c / 12.92;
    vec3 high = pow((c + vec3(0.055)) / 1.055, vec3(2.4));
    return dot(mix(low, high, step(vec3(0.03928), c)), vec3(0.2126,0.7152,0.0722));
}

// The app's existing dark appearance uses light ink. Match adapt.js's 15-point
// trimmed sample, density and chroma retention without reading GPU pixels back.
vec3 material(vec3 backdrop) {
    vec3 sum = vec3(0.0), low1 = vec3(1.0), low2 = vec3(1.0);
    vec3 high1 = vec3(0.0), high2 = vec3(0.0);
    float min1 = 2.0, min2 = 2.0, max1 = -1.0, max2 = -1.0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 5; x++) {
            vec3 c = sampleScene(uSize * vec2(0.18+0.16*float(x), 0.24+0.26*float(y))).rgb;
            float l = dot(c, vec3(0.299,0.587,0.114));
            sum += c;
            if (l < min1) { min2=min1; low2=low1; min1=l; low1=c; }
            else if (l < min2) { min2=l; low2=c; }
            if (l > max1) { max2=max1; high2=high1; max1=l; high1=c; }
            else if (l > max2) { max2=l; high2=c; }
        }
    }
    vec3 mean = (sum-low1-low2-high1-high2)/11.0;
    float luma = dot(mean,vec3(0.299,0.587,0.114));
    float chroma = max(mean.r,max(mean.g,mean.b))-min(mean.r,min(mean.g,mean.b));
    float density = clamp(smoothstep(0.12,0.52,luma)*0.55 + (max1-min1)*0.7 + chroma*0.3,0.0,1.0);
    float saturation = 1.6 * clamp(1.0-chroma*0.75,0.45,1.0);
    vec3 tone = clamp(mix(vec3(dot(backdrop,vec3(0.213,0.715,0.072))),backdrop,saturation)*0.8,0.0,1.0);
    vec3 tint = vec3(30.0,30.0,34.0)/255.0;
    float alpha = mix(0.16,0.38,density);
    // Keep even the secondary label readable. Increase only the tint needed,
    // instead of flattening every sampled color to a fixed maximum brightness.
    float lo=alpha, hi=0.9;
    float ink=luminance(vec3(209.0,209.0,218.0)/255.0);
    for (int i=0;i<12;i++) {
        float mid=(lo+hi)*0.5;
        float contrast=(ink+0.05)/(luminance(mix(tone,tint,mid))+0.05);
        if (contrast >= 4.5) hi=mid; else lo=mid;
    }
    return mix(tone,tint,hi);
}

void main() {
    vec2 point = FlutterFragCoord().xy;
    vec2 halfSize = uSize * 0.5;
    float radius = min(uRadius * uScale, min(halfSize.x, halfSize.y));
    vec2 local = point - halfSize;
    vec2 q = abs(local) - halfSize + radius;
    float depth = radius - length(max(q, vec2(0.0))) - min(max(q.x, q.y), 0.0);
    float rim = max(1.0, min(40.0 * uScale, min(uSize.x, uSize.y) / 3.5));
    vec2 axis = q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec2 normal = max(q.x,q.y) > 0.0 ? normalize(max(q, vec2(0.0001))) : axis;
    vec2 offset = -sign(local) * normal * rim * 1.1 * pow(clamp(1.0-depth/rim, 0.0, 1.0), 2.6);
    vec3 color = vec3(blurred(point+offset*1.15).r, blurred(point+offset).g,
                      blurred(point+offset*0.85).b);
    fragColor = vec4(material(color),1.0);
}
