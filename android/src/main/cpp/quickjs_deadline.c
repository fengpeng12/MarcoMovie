/* First-party cancellation bridge for pinned quickjs-wrapper 3.2.3.
 * Does not replace JSRuntime opaque data or access its internal layout. */
#include <jni.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

typedef struct JSRuntime JSRuntime;
typedef int JSInterruptHandler(JSRuntime *, void *);
extern void JS_SetInterruptHandler(JSRuntime *, JSInterruptHandler *, void *);

typedef struct Deadline {
    jlong handle;
    jlong generation;
    JSRuntime *runtime;
    atomic_uint_fast64_t deadline_ms;
    atomic_int cancelled;
    atomic_int reason;
    struct Deadline *next;
} Deadline;

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static Deadline *registry;
static uint64_t next_handle = 1;
static unsigned count;

static uint64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return UINT64_MAX;
    return (uint64_t) now.tv_sec * 1000u + (uint64_t) now.tv_nsec / 1000000u;
}

static void fail(JNIEnv *env, const char *message) {
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (type) (*env)->ThrowNew(env, type, message);
}

/* Callback is called only by QuickJS on its owning executor. Cross-thread
 * cancellation writes atomics under the registry lock; stale handles are inert. */
static int interrupt(JSRuntime *runtime, void *opaque) {
    (void) runtime;
    Deadline *state = opaque;
    if (atomic_load_explicit(&state->cancelled, memory_order_acquire)) {
        atomic_store_explicit(&state->reason, 2, memory_order_release);
        return 1;
    }
    uint64_t end = atomic_load_explicit(&state->deadline_ms, memory_order_acquire);
    if (end && monotonic_ms() >= end) {
        atomic_store_explicit(&state->reason, 1, memory_order_release);
        return 1;
    }
    return 0;
}

static Deadline *find(jlong handle) {
    for (Deadline *state = registry; state; state = state->next)
        if (state->handle == handle) return state;
    return NULL;
}

JNIEXPORT jlong JNICALL
Java_com_pilipala_marcomovie_QuickJsDeadline_attach0(JNIEnv *env, jclass type, jobject context) {
    (void) type;
    jclass expected = (*env)->FindClass(env, "com/whl/quickjs/wrapper/QuickJSContext");
    jclass actual = context ? (*env)->GetObjectClass(env, context) : NULL;
    if (!expected || !actual || !(*env)->IsSameObject(env, expected, actual)) {
        fail(env, "Unsupported QuickJS wrapper class; expected 3.2.3");
        return 0;
    }
    jfieldID field = (*env)->GetFieldID(env, expected, "runtime", "J");
    if (!field) return 0; /* JNI's missing-field exception fails closed. */
    JSRuntime *runtime = (JSRuntime *) (intptr_t) (*env)->GetLongField(env, context, field);
    (*env)->DeleteLocalRef(env, actual);
    (*env)->DeleteLocalRef(env, expected);
    if (!runtime) { fail(env, "QuickJS runtime is unavailable"); return 0; }
    pthread_mutex_lock(&registry_lock);
    for (Deadline *item = registry; item; item = item->next)
        if (item->runtime == runtime) {
            pthread_mutex_unlock(&registry_lock);
            fail(env, "QuickJS runtime already has a deadline owner");
            return 0;
        }
    if (count >= 128 || next_handle > INT64_MAX) {
        pthread_mutex_unlock(&registry_lock);
        fail(env, "QuickJS deadline capacity exceeded");
        return 0;
    }
    Deadline *state = calloc(1, sizeof(*state));
    if (!state) {
        pthread_mutex_unlock(&registry_lock);
        fail(env, "Cannot allocate QuickJS deadline");
        return 0;
    }
    state->handle = (jlong) next_handle++;
    state->runtime = runtime;
    atomic_init(&state->deadline_ms, 0);
    atomic_init(&state->cancelled, 0);
    atomic_init(&state->reason, 0);
    state->next = registry;
    registry = state;
    count++;
    JS_SetInterruptHandler(runtime, interrupt, state);
    pthread_mutex_unlock(&registry_lock);
    return state->handle;
}

JNIEXPORT void JNICALL
Java_com_pilipala_marcomovie_QuickJsDeadline_arm0(JNIEnv *env, jclass type, jlong handle,
        jlong generation, jlong timeout_ms) {
    (void) type;
    pthread_mutex_lock(&registry_lock);
    Deadline *state = find(handle);
    if (!state || generation <= state->generation || timeout_ms < 1 || timeout_ms > 45000) {
        pthread_mutex_unlock(&registry_lock);
        fail(env, "Invalid QuickJS deadline operation");
        return;
    }
    state->generation = generation;
    atomic_store_explicit(&state->cancelled, 0, memory_order_release);
    atomic_store_explicit(&state->reason, 0, memory_order_release);
    uint64_t now = monotonic_ms();
    atomic_store_explicit(&state->deadline_ms,
            now == UINT64_MAX ? 1 : now + (uint64_t) timeout_ms, memory_order_release);
    pthread_mutex_unlock(&registry_lock);
}

JNIEXPORT void JNICALL
Java_com_pilipala_marcomovie_QuickJsDeadline_cancel0(JNIEnv *env, jclass type, jlong handle,
        jlong generation) {
    (void) env; (void) type;
    pthread_mutex_lock(&registry_lock);
    Deadline *state = find(handle);
    if (state && state->generation == generation)
        atomic_store_explicit(&state->cancelled, 1, memory_order_release);
    pthread_mutex_unlock(&registry_lock);
}

JNIEXPORT jint JNICALL
Java_com_pilipala_marcomovie_QuickJsDeadline_finish0(JNIEnv *env, jclass type, jlong handle,
        jlong generation) {
    (void) type;
    pthread_mutex_lock(&registry_lock);
    Deadline *state = find(handle);
    if (!state || state->generation != generation) {
        pthread_mutex_unlock(&registry_lock);
        fail(env, "QuickJS deadline operation is unavailable");
        return 2;
    }
    int reason = atomic_load_explicit(&state->reason, memory_order_acquire);
    if (!reason && atomic_load_explicit(&state->cancelled, memory_order_acquire)) reason = 2;
    uint64_t end = atomic_load_explicit(&state->deadline_ms, memory_order_acquire);
    if (!reason && end && monotonic_ms() >= end) reason = 1;
    atomic_store_explicit(&state->deadline_ms, 0, memory_order_release);
    atomic_store_explicit(&state->cancelled, 0, memory_order_release);
    pthread_mutex_unlock(&registry_lock);
    return reason;
}

JNIEXPORT void JNICALL
Java_com_pilipala_marcomovie_QuickJsDeadline_detach0(JNIEnv *env, jclass type, jlong handle) {
    (void) env; (void) type;
    pthread_mutex_lock(&registry_lock);
    Deadline **item = &registry;
    while (*item && (*item)->handle != handle) item = &(*item)->next;
    if (*item) {
        Deadline *state = *item;
        /* This method is called on the runtime owner, before runtime destruction. */
        JS_SetInterruptHandler(state->runtime, NULL, NULL);
        *item = state->next;
        count--;
        free(state);
    }
    pthread_mutex_unlock(&registry_lock);
}
