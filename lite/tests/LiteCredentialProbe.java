package com.pilipala.marcomovie.lite;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONObject;

public final class LiteCredentialProbe {
    static String read(String url) throws Exception {
        java.net.HttpURLConnection c = (java.net.HttpURLConnection)new URL(url).openConnection();
        c.setConnectTimeout(5000); c.setReadTimeout(5000);
        try(java.io.InputStream in = c.getInputStream()) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[1024]; int n;
            while((n=in.read(buf))!=-1) out.write(buf,0,n);
            return new String(out.toByteArray(),StandardCharsets.UTF_8);
        } finally { c.disconnect(); }
    }
    public static void main(String[] args) throws Exception {
        final Map<String,Map<String,String>> received = new ConcurrentHashMap<>();
        HttpServer media=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        HttpServer source=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        LiteMediaProxy proxy=LiteMediaProxy.get();
        try {
            media.createContext("/", exchange -> {
                Map<String,String> headers = new LinkedHashMap<>();
                for(String name:new String[]{"Authorization","Cookie"}) {
                    String value=exchange.getRequestHeaders().getFirst(name);
                    if(value!=null)headers.put(name,value);
                }
                received.put(exchange.getRequestURI().getPath(),headers);
                byte[] body="fixture-only".getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(200,body.length);
                exchange.getResponseBody().write(body);exchange.close();
            });
            final String base="http://127.0.0.1:"+media.getAddress().getPort();
            source.createContext("/list.m3u8", exchange -> {
                String playlist="#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\""+base+"/key\"\n#EXTINF:5,\n"+base+"/segment.ts\n#EXT-X-ENDLIST\n";
                byte[] body=playlist.getBytes(StandardCharsets.UTF_8);
                exchange.getResponseHeaders().set("Content-Type","application/vnd.apple.mpegurl");
                exchange.sendResponseHeaders(200,body.length);
                exchange.getResponseBody().write(body);exchange.close();
            });
            media.start();source.start();
            Map<String,String> credentials=new LinkedHashMap<>();
            credentials.put("Authorization","Bearer review-fixture-only");
            credentials.put("Cookie","session=review-fixture-only");
            String playlist=read(proxy.buildProxyUrl("http://127.0.0.1:"+source.getAddress().getPort()+"/list.m3u8",credentials));
            for(String line:playlist.split("\n")) {
                if(line.startsWith("#EXT-X-KEY")) {
                    int start=line.indexOf("URI=\"")+5;
                    read(line.substring(start,line.indexOf('"',start)));
                } else if(line.startsWith("http"))read(line);
            }
            System.out.println(new JSONObject().put("probe","lite-cross-origin-hls").put("received",received));
            if(received.size()!=2)throw new AssertionError("Fixture did not request both key and segment");
            for(Map<String,String> headers:received.values()) {
                if(!headers.isEmpty())throw new AssertionError("Credentials forwarded to another origin");
            }
        } finally {proxy.close();source.stop(0);media.stop(0);}
    }
}
