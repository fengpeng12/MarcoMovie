package com.pilipala.marcomovie;

import java.io.*;

/** Configuration destination, independent from preferences and media/account storage. */
final class ConfigStore {
    final File directory;

    ConfigStore(File target) {
        directory = target;
    }

    void write(String raw) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("配置目录不可用");
        File pending = File.createTempFile("config-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(raw.getBytes("UTF-8"));
                out.getFD().sync();
            }
            if (!pending.renameTo(new File(directory, "config.json")))
                throw new IOException("无法保存配置，原配置已保留");
        } finally {
            pending.delete();
        }
    }
}
