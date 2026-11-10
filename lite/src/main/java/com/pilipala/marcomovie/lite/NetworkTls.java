// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
import java.security.Provider;
import java.net.Socket;
import java.net.InetAddress;
import java.io.IOException;
import java.util.ArrayList;
import javax.net.ssl.*;
/** Uses the packaged provider or the platform TLS implementation, retaining certificate checks. */
public final class NetworkTls {
 static SSLContext context(TrustManager[] trust)throws Exception {
  SSLContext context;
  try{Class<?> type=Class.forName("org.conscrypt.Conscrypt");Provider provider=(Provider)type.getMethod("newProvider").invoke(null);context=SSLContext.getInstance("TLS",provider);}
  catch(ClassNotFoundException unavailable){context=SSLContext.getInstance("TLS");}
  context.init(null,trust,null);return context;
 }
 public static void configure(HttpsURLConnection connection)throws java.io.IOException {
  try{connection.setSSLSocketFactory(new ModernTlsFactory(context(null).getSocketFactory()));}
  catch(Exception failure){throw new java.io.IOException("HTTPS 加密组件无法初始化",failure);}
  catch(LinkageError failure){throw new java.io.IOException("HTTPS 加密组件不适用于此设备",failure);}
 }

 static final class ModernTlsFactory extends SSLSocketFactory {
  private final SSLSocketFactory delegate;
  ModernTlsFactory(SSLSocketFactory delegate){this.delegate=delegate;}
  static Socket configure(Socket socket)throws IOException {
   if(!(socket instanceof SSLSocket))return socket;
   SSLSocket ssl=(SSLSocket)socket;
   ArrayList<String> protocols=new ArrayList<String>();
   for(String protocol:ssl.getSupportedProtocols())
    if("TLSv1.2".equals(protocol)||"TLSv1.3".equals(protocol))protocols.add(protocol);
   if(protocols.isEmpty()) {
    try{socket.close();}catch(IOException ignored){}
    throw new IOException("此系统的安全连接组件不支持 TLS 1.2，请升级系统或使用兼容的片源");
   }
   ssl.setEnabledProtocols(protocols.toArray(new String[protocols.size()]));
   return socket;
  }
  public String[] getDefaultCipherSuites(){return delegate.getDefaultCipherSuites();}
  public String[] getSupportedCipherSuites(){return delegate.getSupportedCipherSuites();}
  public Socket createSocket()throws IOException{return configure(delegate.createSocket());}
  public Socket createSocket(Socket socket,String host,int port,boolean close)throws IOException{return configure(delegate.createSocket(socket,host,port,close));}
  public Socket createSocket(String host,int port)throws IOException{return configure(delegate.createSocket(host,port));}
  public Socket createSocket(String host,int port,InetAddress local,int localPort)throws IOException{return configure(delegate.createSocket(host,port,local,localPort));}
  public Socket createSocket(InetAddress host,int port)throws IOException{return configure(delegate.createSocket(host,port));}
  public Socket createSocket(InetAddress host,int port,InetAddress local,int localPort)throws IOException{return configure(delegate.createSocket(host,port,local,localPort));}
 }
}
