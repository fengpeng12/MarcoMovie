// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#include <jni.h>

extern int node_start_embedded(int, char **) __asm__("_ZN4node5StartEiPPc");

JNIEXPORT jint JNICALL Java_com_pilipala_catpaw_NodeRuntime_run(
        JNIEnv *env, jclass type, jstring script, jstring root, jstring ready) {
    (void)type;
    jstring input[3] = {script, root, ready};
    char storage[16384];
    char *argv[6];
    int used = 0;
    const char *fixed[2] = {"node", "--embedded"};
    for (int i = 0; i < 5; i++) {
        const char *value = i == 0 ? fixed[0] : i == 4 ? fixed[1]
            : (*env)->GetStringUTFChars(env, input[i - 1], 0);
        if (!value) return -1;
        argv[i] = storage + used;
        int j = 0;
        while (value[j] && used < (int)sizeof(storage) - 1) storage[used++] = value[j++];
        int overflow = value[j] != 0;
        if (i > 0 && i < 4) (*env)->ReleaseStringUTFChars(env, input[i - 1], value);
        if (overflow) return -2;
        storage[used++] = 0;
    }
    argv[5] = 0;
    return node_start_embedded(5, argv);
}
