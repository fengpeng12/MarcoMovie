// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/** Short-lived phone configuration endpoint; never logs or echoes imported credentials. */
public final class ConfigServer {
 public interface Importer {void apply(String address)throws Exception;}
 private final ServerSocket server;private final Importer importer;
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private volatile boolean closed;private volatile Socket active;
 public final String token=UUID.randomUUID().toString();
 public ConfigServer(Importer sink)throws IOException {importer=sink;server=new ServerSocket(0,4);worker.execute(new Runnable(){public void run(){serve();}});}
 public int port(){return server.getLocalPort();}
 public void close(){closed=true;try{server.close();}catch(Exception ignored){}try{if(active!=null)active.close();}catch(Exception ignored){}worker.shutdownNow();}
 private static String line(InputStream in)throws IOException {ByteArrayOutputStream b=new ByteArrayOutputStream();int c;while((c=in.read())!=-1){if(c=='\n')return new String(b.toByteArray(),"US-ASCII").trim();if(b.size()>=4096)throw new IOException("header limit");b.write(c);}throw new EOFException();}
 private void serve(){while(!closed){Socket s=null;try{s=server.accept();active=s;s.setSoTimeout(5000);handle(s);}catch(Exception ignored){}finally{try{if(s!=null)s.close();}catch(Exception ignored){}active=null;}}}
 private void reply(Socket s,int code,String body)throws IOException {byte[] b=body.getBytes("UTF-8");OutputStream o=s.getOutputStream();o.write(("HTTP/1.1 "+code+" Response\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: "+b.length+"\r\n\r\n").getBytes("US-ASCII"));o.write(b);o.flush();}
 private void handle(Socket s)throws Exception {
  InputStream in=s.getInputStream();String[] request=line(in).split(" ");int length=0;String transfer="",content="";
  for(int i=0;i<40;i++){String h=line(in);if(h.length()==0)break;int colon=h.indexOf(':');if(colon<0)throw new IOException();String k=h.substring(0,colon).toLowerCase(Locale.US),v=h.substring(colon+1).trim();if(k.equals("content-length"))length=Integer.parseInt(v);if(k.equals("transfer-encoding"))transfer=v;if(k.equals("content-type"))content=v;if(i==39)throw new IOException();}
  if(request.length!=3||!request[1].equals("/"+token)){reply(s,403,"配对已失效，请重新扫码");return;}
  if(request[0].equals("GET")){reply(s,200,"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Marco Movie Lite</title><h1>配置电视</h1><p>请输入你自行获取的配置地址。软件不提供影视资源。</p><form method=post><input name=url type=url required placeholder='https://…' size=35><button>提交到电视</button></form><p>提交完成前请保持电视配置页打开。</p>");return;}
  if(!request[0].equals("POST")){reply(s,405,"不支持的操作");return;}
  if(length<1||length>8192||transfer.length()>0||!content.startsWith("application/x-www-form-urlencoded")){reply(s,400,"提交格式不正确");return;}
  byte[] b=new byte[length];int p=0,n;while(p<length&&(n=in.read(b,p,length-p))>0)p+=n;if(p!=length)throw new EOFException();String address=null;
  for(String field:new String(b,"UTF-8").split("&")){String[] kv=field.split("=",2);if(kv.length==2&&kv[0].equals("url"))address=URLDecoder.decode(kv[1],"UTF-8");}
  try{if(address==null)throw new IOException();importer.apply(LiteCatalog.http(address));reply(s,200,"<meta charset=utf-8><h2>配置已保存到电视</h2><p>请返回电视选择片源。</p>");}
  catch(Exception failure){reply(s,422,"<meta charset=utf-8><h2>导入失败，原配置已保留</h2><p>请检查配置地址、网络及旧系统 HTTPS 兼容性，然后重试。</p>");}
 }
}
