package com.pilipala.marcomovie.lite;
import android.app.*;import android.os.*;import android.content.*;import android.view.*;import java.net.*;import java.io.*;import org.json.*;
public final class LiteProbe extends Instrumentation {
 int count;LiteActivity a;boolean candidate;
 void check(boolean value,String name){if(!value)throw new AssertionError(name);count++;}
 void main(Runnable job){runOnMainSync(job);}
 String request(int port,String path,String data)throws Exception {HttpURLConnection c=(HttpURLConnection)new URL("http://127.0.0.1:"+port+path).openConnection();c.setConnectTimeout(3000);c.setReadTimeout(20000);if(data!=null){c.setDoOutput(true);c.setRequestMethod("POST");c.setRequestProperty("Content-Type","application/x-www-form-urlencoded");byte[] bytes=data.getBytes("UTF-8");c.setFixedLengthStreamingMode(bytes.length);c.getOutputStream().write(bytes);}int code=c.getResponseCode();InputStream in=code>=400?c.getErrorStream():c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] b=new byte[1024];int n;while((n=in.read(b))!=-1)out.write(b,0,n);c.disconnect();return code+":"+new String(out.toByteArray(),"UTF-8");}
 public void onCreate(Bundle b){super.onCreate(b);candidate="true".equals(b.getString("candidate"));start();}
 public void onStart(){Bundle result=new Bundle();try{
  check(Build.VERSION.SDK_INT==14,"real API14 runtime");
  a=(LiteActivity)startActivitySync(new Intent(getTargetContext(),LiteActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
  check(a!=null,"launch");
  a.getPreferences(0).edit().putBoolean("experimental_decoder",candidate).commit();
  check(LiteCatalog.query("http://example.invalid/api","wd","中文 a").contains("%E4%B8%AD"),"query encoding");
  try{LiteCatalog.http("file:///private");throw new AssertionError("scheme");}catch(IOException ok){count++;}
  main(new Runnable(){public void run(){a.configure();}});check(a.pairing!=null,"pair server and QR generated");int port=a.pairing.port();String path="/"+a.pairing.token;
  check(request(port,path,null).startsWith("200:"),"phone page");
  check(request(port,"/wrong",null).startsWith("403:"),"invalid pairing rejected");
  String fixture="http://10.0.2.2:8773/config";
  check(request(port,path,"url="+URLEncoder.encode(fixture,"UTF-8")).startsWith("200:"),"phone submit succeeds");
  check(a.getPreferences(0).getString("address","").equals(fixture),"configuration persisted");
  String saved=a.getPreferences(0).getString("config","");
  check(request(port,path,"url="+URLEncoder.encode("http://10.0.2.2:8773/invalid","UTF-8")).startsWith("422:"),"invalid config rejected");
  check(saved.equals(a.getPreferences(0).getString("config","")),"failed import preserves config");
  main(new Runnable(){public void run(){a.home();}});check(a.pairing==null,"pairing closes when leaving");check(a.sites.size()==2,"sites retained");check(a.sites.get(0).supported&&!a.sites.get(1).supported,"unsupported plugin explicit");
  main(new Runnable(){public void run(){a.selected=a.sites.get(0);a.catalog("",1);}});SystemClock.sleep(2500);check(a.status.getText().toString().contains("1"),"CMS list loaded");
  main(new Runnable(){public void run(){a.detail("demo");}});SystemClock.sleep(2500);check(a.currentDetail!=null,"detail and episode loaded");
  main(new Runnable(){public void run(){a.play("http://10.0.2.2:8773/video.mp4","合成播放测试");}});
  long deadline=SystemClock.uptimeMillis()+30000;while(!a.ready&&SystemClock.uptimeMillis()<deadline)SystemClock.sleep(200);check(a.ready,"system player prepared");
  final int[] pos=new int[2];main(new Runnable(){public void run(){pos[0]=a.player.getCurrentPosition();}});SystemClock.sleep(1500);main(new Runnable(){public void run(){pos[1]=a.player.getCurrentPosition();}});check(pos[1]>pos[0],"playback clock advances");
  main(new Runnable(){public void run(){a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_DPAD_CENTER));}});check(!a.player.isPlaying(),"remote pause");
  main(new Runnable(){public void run(){a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_DPAD_CENTER));}});check(a.player.isPlaying(),"remote resume");
  main(new Runnable(){public void run(){a.onBackPressed();}});check(a.player==null&&a.currentDetail!=null,"back releases playback to episodes");
  main(new Runnable(){public void run(){a.play("http://10.0.2.2:8773/stream.m3u8","HLS 合成测试");}});
  deadline=SystemClock.uptimeMillis()+30000;while(!a.ready&&SystemClock.uptimeMillis()<deadline)SystemClock.sleep(200);check(a.ready,"HLS prepared");
  check(a.player.name().contains(candidate?"IJK":"系统"),"selected backend active");
  main(new Runnable(){public void run(){pos[0]=a.player.getCurrentPosition();}});SystemClock.sleep(1500);main(new Runnable(){public void run(){pos[1]=a.player.getCurrentPosition();}});check(pos[1]>pos[0],"HLS clock advances");
  main(new Runnable(){public void run(){a.player.seekTo(18000);}});SystemClock.sleep(3000);main(new Runnable(){public void run(){pos[1]=a.player.getCurrentPosition();}});check(pos[1]>=15000,"HLS seek progresses");
  main(new Runnable(){public void run(){callActivityOnStop(a);}});check(a.player==null,"background releases decoder");
  main(new Runnable(){public void run(){callActivityOnStart(a);}});check(!a.homeVisible&&a.currentDetail!=null,"foreground returns to usable detail");
  main(new Runnable(){public void run(){a.onBackPressed();}});check(a.player==null,"HLS released");
  if(candidate){
   check(NetworkTls.context(null).getProvider().getName().contains("Conscrypt"),"candidate TLS provider loads on API14");
   try{LiteCatalog.fetch("https://10.0.2.2:8774/config",null);throw new AssertionError("untrusted certificate accepted");}catch(javax.net.ssl.SSLException expected){count++;}
   java.security.cert.CertificateFactory cf=java.security.cert.CertificateFactory.getInstance("X.509");
   InputStream cert=getContext().getAssets().open("test-ca.pem");java.security.cert.Certificate ca=cf.generateCertificate(cert);cert.close();
   java.security.KeyStore store=java.security.KeyStore.getInstance(java.security.KeyStore.getDefaultType());store.load(null,null);store.setCertificateEntry("test",ca);
   javax.net.ssl.TrustManagerFactory trust=javax.net.ssl.TrustManagerFactory.getInstance(javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm());trust.init(store);
   javax.net.ssl.SSLContext tls=NetworkTls.context(trust.getTrustManagers());
   javax.net.ssl.HttpsURLConnection c=(javax.net.ssl.HttpsURLConnection)new URL("https://10.0.2.2:8774/config").openConnection();c.setSSLSocketFactory(tls.getSocketFactory());c.setConnectTimeout(5000);c.setReadTimeout(5000);check(c.getResponseCode()==200,"TLS1.2 request with trusted test CA");c.disconnect();
   javax.net.ssl.SSLSocket socket=(javax.net.ssl.SSLSocket)tls.getSocketFactory().createSocket("10.0.2.2",8774);socket.setSoTimeout(5000);socket.startHandshake();check(socket.getSession().getProtocol().equals("TLSv1.2"),"TLS1.2 negotiated");check(!javax.net.ssl.HttpsURLConnection.getDefaultHostnameVerifier().verify("wrong.example",socket.getSession()),"hostname mismatch rejected");socket.close();
  }
  result.putString("stream","PASS "+count+" API14 checks\n");finish(Activity.RESULT_OK,result);
 }catch(Throwable failure){result.putString("stream","FAIL after "+count+": "+failure.toString()+"\n");finish(Activity.RESULT_CANCELED,result);}finally{if(a!=null)main(new Runnable(){public void run(){a.finish();}});}}
}
