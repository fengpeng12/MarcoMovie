// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
import android.content.Context;
import android.view.SurfaceHolder;
import java.util.Map;

/** App-owned interface: importing a decoder never changes the UI's Android API floor. */
public interface LitePlayer {
 interface Listener {void prepared();void error(int what,int extra);void size(int width,int height);void completed();}
 void open(Context context,String address,Map<String,String> headers,SurfaceHolder holder,Listener listener)throws Exception;
 void start();void pause();void release();void seekTo(int position);
 boolean isPlaying();int getCurrentPosition();int getDuration();String name();
}
