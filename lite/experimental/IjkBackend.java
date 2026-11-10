// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
import android.content.Context;import android.view.SurfaceHolder;import java.util.Map;
import tv.danmaku.ijk.media.player.*;
/** Isolated legacy candidate. Never included in the default public build. */
public final class IjkBackend implements LitePlayer {
 private final IjkMediaPlayer player=new IjkMediaPlayer();private boolean released;
 public void open(Context context,String address,Map<String,String> headers,SurfaceHolder holder,final Listener listener)throws Exception {
  // API14 has no MediaCodec. Use CPU decoding and NativeWindow without a GL dependency.
  player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER,"mediacodec",0);
  player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER,"overlay-format",842225234);
  player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER,"opensles",0);
  player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT,"protocol_whitelist","http,tcp,file,crypto");
  player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT,"timeout",15000000);
  player.setDisplay(holder);
  player.setOnPreparedListener(new IMediaPlayer.OnPreparedListener(){public void onPrepared(IMediaPlayer p){if(!released)listener.prepared();}});
  player.setOnErrorListener(new IMediaPlayer.OnErrorListener(){public boolean onError(IMediaPlayer p,int w,int e){if(!released)listener.error(w,e);return true;}});
  player.setOnVideoSizeChangedListener(new IMediaPlayer.OnVideoSizeChangedListener(){public void onVideoSizeChanged(IMediaPlayer p,int w,int h,int sn,int sd){if(!released)listener.size(sn>0&&sd>0?(int)((long)w*sn/sd):w,h);}});
  player.setOnCompletionListener(new IMediaPlayer.OnCompletionListener(){public void onCompletion(IMediaPlayer p){if(!released)listener.completed();}});
  if(!address.startsWith("http://"))throw new java.io.IOException("实验内核暂只验证 HTTP 合成媒体");
  player.setDataSource(address,headers);player.prepareAsync();
 }
 public void start(){player.start();}public void pause(){player.pause();}public void release(){if(!released){released=true;player.release();}}
 public void seekTo(int p){player.seekTo(p);}public boolean isPlaying(){return !released&&player.isPlaying();}
 public int getCurrentPosition(){return (int)Math.min(Integer.MAX_VALUE,player.getCurrentPosition());}public int getDuration(){return (int)Math.min(Integer.MAX_VALUE,player.getDuration());}public String name(){return "IJK 实验解码";}
}
