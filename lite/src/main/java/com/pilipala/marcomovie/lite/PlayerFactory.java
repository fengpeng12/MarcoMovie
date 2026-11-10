// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;
public final class PlayerFactory {
 public static boolean hasCandidate(){try{Class.forName("com.pilipala.marcomovie.lite.IjkBackend");return true;}catch(ClassNotFoundException absent){return false;}}
 public static LitePlayer create(boolean candidate)throws Exception {
  if(candidate&&hasCandidate())return (LitePlayer)Class.forName("com.pilipala.marcomovie.lite.IjkBackend").newInstance();
  return new SystemBackend();
 }
}
