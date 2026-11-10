// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
import android.content.Context;import android.media.MediaPlayer;import android.net.Uri;import android.view.SurfaceHolder;import java.util.Map;
public final class SystemBackend implements LitePlayer {
 private final MediaPlayer player=new MediaPlayer();private boolean released;
 public void open(Context context,String address,Map<String,String> headers,SurfaceHolder holder,final Listener listener)throws Exception {
  player.setDisplay(holder);
  player.setOnPreparedListener(new MediaPlayer.OnPreparedListener(){public void onPrepared(MediaPlayer p){if(!released)listener.prepared();}});
  player.setOnErrorListener(new MediaPlayer.OnErrorListener(){public boolean onError(MediaPlayer p,int what,int extra){if(!released)listener.error(what,extra);return true;}});
  player.setOnVideoSizeChangedListener(new MediaPlayer.OnVideoSizeChangedListener(){public void onVideoSizeChanged(MediaPlayer p,int w,int h){if(!released)listener.size(w,h);}});
  player.setOnCompletionListener(new MediaPlayer.OnCompletionListener(){public void onCompletion(MediaPlayer p){if(!released)listener.completed();}});
  player.setDataSource(context,Uri.parse(address),headers);player.prepareAsync();
 }
 public void start(){player.start();}public void pause(){player.pause();}
 public void release(){if(!released){released=true;player.release();}}
 public void seekTo(int position){player.seekTo(position);}public boolean isPlaying(){return !released&&player.isPlaying();}
 public int getCurrentPosition(){return player.getCurrentPosition();}public int getDuration(){return player.getDuration();}public String name(){return "系统解码";}
}
