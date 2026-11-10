package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.List;

/** Explicit defaults remain separate from a one-time manual source switch. */
final class SourcePreferences {
    private static String identity(Cms.Site site) {
        return site.key + "\n" + site.api;
    }

    static boolean isPreferred(MainActivity a, Cms.Site site) {
        return identity(site).equals(a.prefs.getString(Prefs.PREFERRED_SITE, ""));
    }

    static void restoreDefault(MainActivity a) {
        if (a.config == null) return;
        for (Cms.Site site : a.config.sites) {
            if (isPreferred(a, site) && a.available(site)) {
                a.prefs.edit().putString(Prefs.SELECTED_SITE, site.key).apply();
                return;
            }
        }
    }

    static void choose(MainActivity a) {
        if (a.config == null) return;
        List<Cms.Site> sites = new ArrayList<>();
        for (Cms.Site site : a.config.sites) if (a.available(site)) sites.add(site);
        String[] names = new String[sites.size() + 1];
        names[0] = "跟随上次选择";
        for (int i = 0; i < sites.size(); i++)
            names[i + 1] = (isPreferred(a, sites.get(i)) ? "★ " : "") + sites.get(i).name;
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("默认偏好源")
                .setItems(
                        names,
                        (d, index) -> {
                            a.prefs
                                    .edit()
                                    .putString(
                                            Prefs.PREFERRED_SITE,
                                            index == 0 ? "" : identity(sites.get(index - 1)))
                                    .apply();
                            a.toast(index == 0 ? "已取消默认偏好源" : "已保存默认偏好源");
                            SourcePicker.show(a);
                        })
                .show();
    }

    static int lineIndex(MainActivity a, Cms.Video video) {
        String preferred = a.prefs.getString(Prefs.PREFERRED_LINE, "");
        for (int i = 0; i < video.lines.size(); i++) {
            if (video.lines.get(i).name.equals(preferred) && !video.lines.get(i).episodes.isEmpty())
                return i;
        }
        for (int i = 0; i < video.lines.size(); i++)
            if (!video.lines.get(i).episodes.isEmpty()) return i;
        return 0;
    }

    static List<Cms.Site> prioritized(MainActivity a, List<Cms.Site> sites) {
        List<Cms.Site> ordered = new ArrayList<>();
        for (Cms.Site site : sites) if (isPreferred(a, site)) ordered.add(site);
        for (Cms.Site site : sites) if (!isPreferred(a, site)) ordered.add(site);
        return ordered;
    }

    static void chooseLine(MainActivity a, Cms.Video video) {
        String[] names = new String[video.lines.size() + 1];
        names[0] = "自动选择";
        String preferred = a.prefs.getString(Prefs.PREFERRED_LINE, "");
        for (int i = 0; i < video.lines.size(); i++) {
            String name = video.lines.get(i).name;
            names[i + 1] = (name.equals(preferred) ? "★ " : "") + name;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("默认播放线路")
                .setItems(
                        names,
                        (d, index) -> {
                            a.prefs
                                    .edit()
                                    .putString(
                                            Prefs.PREFERRED_LINE,
                                            index == 0 ? "" : video.lines.get(index - 1).name)
                                    .apply();
                            a.toast("已保存，下次打开影片时优先选择；观看记录仍优先续播");
                        })
                .show();
    }
}
