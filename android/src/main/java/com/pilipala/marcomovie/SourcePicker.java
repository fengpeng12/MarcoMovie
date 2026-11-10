package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;

/** The source chooser stays above the current screen and never creates a second navigation page. */
final class SourcePicker {
    private static String profile(String origin) {
        return "source-picker:" + (origin == null ? "" : origin);
    }

    static void applyEdits(MainActivity a, Cms.Config config, String origin) {
        String legacyProfile = profile(origin);
        if (!config.origin.isEmpty()) origin = config.origin;
        String currentProfile = profile(origin);
        if (!currentProfile.equals(legacyProfile)
                && !a.prefs.contains(currentProfile)
                && a.prefs.contains(legacyProfile)) {
            String old = a.prefs.getString(legacyProfile, "{}");
            if (!a.prefs.edit().putString(currentProfile, old).remove(legacyProfile).commit()) {
                // Reading the old edit record still honors deletion if migration cannot persist.
                currentProfile = legacyProfile;
            }
        }
        try {
            org.json.JSONObject saved =
                    new org.json.JSONObject(a.prefs.getString(currentProfile, "{}"));
            org.json.JSONArray order = saved.optJSONArray("order"),
                    removed = saved.optJSONArray("removed");
            java.util.Map<String, Cms.Site> byKey = new java.util.LinkedHashMap<>();
            for (Cms.Site site : config.sites) byKey.put(site.key, site);
            if (removed != null)
                for (int i = 0; i < removed.length(); i++) byKey.remove(removed.optString(i));
            config.sites.clear();
            if (order != null)
                for (int i = 0; i < order.length(); i++) {
                    Cms.Site site = byKey.remove(order.optString(i));
                    if (site != null) config.sites.add(site);
                }
            config.sites.addAll(byKey.values());
        } catch (org.json.JSONException ignored) {
            /* Keep the imported order. */
        }
    }

    static void manage(MainActivity a) {
        Cms.Config config = a.config;
        if (config == null || config.sites.isEmpty()) {
            a.notice("暂无可管理的线路");
            return;
        }
        String[] names = new String[config.sites.size()];
        for (int i = 0; i < names.length; i++) names[i] = config.sites.get(i).name;
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("管理线路")
                .setItems(
                        names,
                        (d, index) -> {
                            Cms.Site site = config.sites.get(index);
                            new AppDialog.Builder(a)
                                    .wrapChoices()
                                    .setTitle(site.name)
                                    .setItems(
                                            new String[] {"上移", "下移", "移到首位", "删除这条线路"},
                                            (action, choice) -> {
                                                if (choice == 3) {
                                                    new AppDialog.Builder(a)
                                                            .wrapChoices()
                                                            .setTitle("删除「" + site.name + "」？")
                                                            .setNegativeButton("取消", null)
                                                            .setPositiveButton(
                                                                    "删除",
                                                                    (ok, which) ->
                                                                            edit(
                                                                                    a, config, site,
                                                                                    -1))
                                                            .show();
                                                } else {
                                                    int target =
                                                            choice == 2
                                                                    ? 0
                                                                    : Math.max(
                                                                            0,
                                                                            Math.min(
                                                                                    names.length
                                                                                            - 1,
                                                                                    index
                                                                                            + (choice
                                                                                                            == 0
                                                                                                    ? -1
                                                                                                    : 1)));
                                                    edit(a, config, site, target);
                                                }
                                            })
                                    .show();
                        })
                .show();
    }

    private static void edit(MainActivity a, Cms.Config config, Cms.Site site, int target) {
        if (a.config != config) return;
        try {
            String key = profile(config.origin.isEmpty() ? a.configOrigin : config.origin);
            org.json.JSONObject saved = new org.json.JSONObject(a.prefs.getString(key, "{}"));
            java.util.List<Cms.Site> sites = new java.util.ArrayList<>(config.sites);
            sites.remove(site);
            if (target >= 0) sites.add(target, site);
            else {
                org.json.JSONArray hidden = saved.optJSONArray("removed");
                if (hidden == null) hidden = new org.json.JSONArray();
                saved.put("removed", hidden.put(site.key));
            }
            org.json.JSONArray order = new org.json.JSONArray();
            for (Cms.Site s : sites) order.put(s.key);
            saved.put("order", order);
            android.content.SharedPreferences.Editor editor =
                    a.prefs.edit().putString(key, saved.toString());
            if (target < 0 && site.key.equals(a.prefs.getString(Prefs.SELECTED_SITE, ""))) {
                editor.remove(Prefs.SELECTED_SITE);
                for (Cms.Site s : sites)
                    if (a.available(s)) {
                        editor.putString(Prefs.SELECTED_SITE, s.key);
                        break;
                    }
            }
            if (!editor.commit()) {
                a.notice("线路变更未能保存，请重试");
                return;
            }
            config.sites.clear();
            config.sites.addAll(sites);
            a.back.clear();
            a.open(new MainActivity.Screen(a::home), false);
            show(a);
        } catch (org.json.JSONException e) {
            a.notice("无法保存线路顺序");
        }
    }

    static void show(MainActivity a) {
        if (a.config == null) {
            a.importDialog();
            return;
        }
        View anchor = a.getCurrentFocus();
        Dialog dialog = new Dialog(a);
        a.sourceDialog = dialog;
        dialog.setOnDismissListener(
                d -> {
                    if (a.sourceDialog == dialog) a.sourceDialog = null;
                    if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
                });
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        boolean tv = a.isTvDevice();
        LinearLayout panel = a.vertical();
        panel.setTag("source-picker");
        panel.setPadding(
                a.dp(tv ? 22 : 16), a.dp(tv ? 18 : 16), a.dp(tv ? 22 : 16), a.dp(tv ? 16 : 14));
        a.glass(panel, 22);

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titleCol = a.vertical();
        LinearLayout titleBadgeRow = a.row();
        titleBadgeRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text("选择片源", tv ? 22 : 19, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        titleBadgeRow.addView(title);
        TextView count = a.text(a.config.sites.size() + " 个片源", 11.5f, 0xff9ca3af);
        count.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
        count.setBackground(a.bg(0x22ffffff, 999));
        LinearLayout.LayoutParams countLp = new LinearLayout.LayoutParams(-2, -2);
        countLp.leftMargin = a.dp(8);
        titleBadgeRow.addView(count, countLp);
        titleCol.addView(titleBadgeRow);
        TextView hint = a.text("选择后返回首页，显示该片源的内容", 12, MainActivity.MUTED);
        hint.setPadding(0, a.dp(2), 0, 0);
        titleCol.addView(hint);
        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

        boolean hasExtraTopActions = a.config.depots.length() > 0 || CatPawSettings.available(a);
        Button prefBtn =
                a.navButton(
                        "默认偏好源",
                        "source-preferred",
                        () -> {
                            dialog.dismiss();
                            SourcePreferences.choose(a);
                        });
        prefBtn.setTextSize(12.5f);
        prefBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
        prefBtn.setMinHeight(a.dp(34));
        prefBtn.setMinimumHeight(a.dp(34));
        if (!hasExtraTopActions) {
            headerRow.addView(prefBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
        }
        panel.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        if (hasExtraTopActions) {
            a.gap(panel, 8);
            LinearLayout topActions = a.row();
            if (a.config.depots.length() > 0) {
                Button depotBtn =
                        a.navButton(
                                "切换子仓库",
                                "warehouse-switch",
                                () -> {
                                    dialog.dismiss();
                                    showWarehouses(a);
                                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(34), 1);
                lp.rightMargin = a.dp(6);
                topActions.addView(depotBtn, lp);
            }
            LinearLayout.LayoutParams prefLp = new LinearLayout.LayoutParams(0, a.dp(34), 1);
            if (CatPawSettings.available(a)) prefLp.rightMargin = a.dp(6);
            topActions.addView(prefBtn, prefLp);
            if (CatPawSettings.available(a)) {
                Button catBtn =
                        a.navButton(
                                "CatPaw 配置",
                                "catpaw-settings",
                                () -> {
                                    dialog.dismiss();
                                    CatPawSettings.choose(a);
                                });
                topActions.addView(catBtn, new LinearLayout.LayoutParams(0, a.dp(34), 1));
            }
            panel.addView(topActions, new LinearLayout.LayoutParams(-1, -2));
        }
        a.gap(panel, 8);
        ScrollView scrolling = new TvScrollView(a);
        scrolling.setVerticalScrollBarEnabled(false);
        LinearLayout grid = a.vertical();
        grid.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
        scrolling.addView(grid);
        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(android.graphics.Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.setClipChildren(true);
        viewport.setClipToPadding(true);
        viewport.addView(scrolling, new FrameLayout.LayoutParams(-1, -1));
        int defaultViewportH = a.dp(tv ? 330 : 370);
        panel.addView(viewport, new LinearLayout.LayoutParams(-1, defaultViewportH));
        String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Button selectedButton = null;
        LinearLayout row = null;
        float fontScale = a.getResources().getConfiguration().fontScale;
        int availWidth = Math.min(a.windowWidth(), a.dp(740)) - a.dp(tv ? 52 : 36);
        int targetColWidth = a.dp(tv ? 200 : 142);
        int columns =
                Math.max(
                        tv ? 2 : (fontScale > 1.35f ? 1 : 2),
                        Math.min(
                                3,
                                (int) (availWidth / (targetColWidth * Math.max(1f, fontScale)))));
        int index = 0;
        for (Cms.Site site : a.config.sites) {
            if (index % columns == 0) {
                row = a.row();
                row.setClipChildren(false);
                grid.addView(row);
            }
            boolean current = site.key.equals(selected);
            Button button =
                    a.button(
                            (current ? "✓ " : "")
                                    + (SourcePreferences.isPreferred(a, site) ? "★ " : "")
                                    + site.name,
                            "source-choice:" + site.key,
                            () -> {
                                if (site.api.startsWith("catpaw://")
                                        && android.net.Uri.parse(site.api)
                                                .getPath()
                                                .equals("/api/baseset")) {
                                    dialog.dismiss();
                                    CatPawSettings.open(a, site);
                                    return;
                                }
                                if (!a.available(site)) {
                                    a.notice("这个片源需要启用来源扩展，或仍有接口待适配。可以在设置中查看。");
                                    return;
                                }
                                a.prefs
                                        .edit()
                                        .putString(Prefs.SELECTED_SITE, site.key)
                                        .putString(Prefs.LOADING_SITE, site.key)
                                        .commit();
                                dialog.dismiss();
                                a.back.clear();
                                a.open(new MainActivity.Screen(a::home), false);
                            });
            button.setTextSize(tv ? 13.5f : 12.8f);
            button.setSingleLine(false);
            button.setMaxLines(2);
            button.setEllipsize(android.text.TextUtils.TruncateAt.END);
            button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
            int cellH = a.dp(tv ? 44 : 40);
            button.setMinHeight(cellH);
            button.setMinimumHeight(cellH);
            button.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
            boolean enabled = a.available(site);
            button.setSelected(current);
            Runnable paint =
                    () -> {
                        boolean focused = button.hasFocus();
                        FocusMotion.style(
                                a,
                                button,
                                focused,
                                current ? 0xff2b384e : 0xff22252a,
                                MainActivity.WHITE,
                                11,
                                enabled
                                        ? (current ? 0xff7dd3fc : MainActivity.WHITE)
                                        : MainActivity.MUTED,
                                MainActivity.DARK,
                                false,
                                1.02f);
                    };
            button.setOnFocusChangeListener((v, f) -> paint.run());
            paint.run();
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1);
            lp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
            row.addView(button, lp);
            if (current) selectedButton = button;
            index++;
        }
        if (row != null)
            while (index++ % columns != 0) {
                LinearLayout.LayoutParams blankLp = new LinearLayout.LayoutParams(0, 1, 1);
                blankLp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
                row.addView(new View(a), blankLp);
            }
        a.gap(panel, 8);
        LinearLayout footer = a.row();
        a.addButton(
                footer,
                a.navButton(
                        "管理线路",
                        "source-manage",
                        () -> {
                            dialog.dismiss();
                            manage(a);
                        }));
        a.addButton(
                footer,
                a.navButton(
                        "更新配置",
                        "source-update",
                        () -> {
                            dialog.dismiss();
                            a.importDialog();
                        }));
        a.addButton(footer, a.navButton("完成", "source-close", dialog::dismiss));
        for (int i = 0; i < footer.getChildCount(); i++) {
            View control = footer.getChildAt(i);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, a.dp(38), 1);
            params.setMargins(a.dp(3), a.dp(2), a.dp(3), a.dp(2));
            control.setLayoutParams(params);
            if (control instanceof TextView) {
                ((TextView) control).setSingleLine(true);
                ((TextView) control).setEllipsize(android.text.TextUtils.TruncateAt.END);
                ((TextView) control).setTextSize(13);
                control.setPadding(a.dp(8), 0, a.dp(8), 0);
            }
        }
        panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));
        int marginH = tv ? a.dp(48) : a.dp(20);
        int panelWidth = Math.min(a.dp(740), a.windowWidth() - marginH);
        int maxHeight = Math.max(a.dp(180), a.windowHeight() - a.dp(tv ? 32 : 84));
        panel.measure(
                View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int controlsHeight = panel.getMeasuredHeight() - defaultViewportH;
        viewport.setLayoutParams(
                new LinearLayout.LayoutParams(
                        -1,
                        Math.max(
                                a.dp(96),
                                Math.min(a.dp(tv ? 360 : 410), maxHeight - controlsHeight))));
        panel.measure(
                View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        if (panel.getMeasuredHeight() > maxHeight) {
            ScrollView outer = new TvScrollView(a);
            outer.addView(panel);
            dialog.setContentView(outer, new ViewGroup.LayoutParams(panelWidth, maxHeight));
        } else dialog.setContentView(panel);
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.setLayout(panelWidth, -2);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams params = window.getAttributes();
            params.dimAmount = .65f;
            window.setAttributes(params);
        }
        Button focus = selectedButton;
        dialog.setOnShowListener(
                d -> {
                    if (focus != null) focus.requestFocus();
                    else if (grid.getChildCount() > 0)
                        ((LinearLayout) grid.getChildAt(0)).getChildAt(0).requestFocus();
                });
        dialog.show();
        if (window != null) window.setLayout(Math.min(a.dp(720), a.root.getWidth() - marginH), -2);
    }

    static void showWarehouses(MainActivity a) {
        Cms.Config previous = a.config;
        org.json.JSONArray rows = previous.depots;
        String[] names = new String[rows.length()];
        for (int i = 0; i < names.length; i++) names[i] = rows.optJSONObject(i).optString("name");
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("切换子仓库")
                .setItems(
                        names,
                        (dialog, index) -> {
                            String url = rows.optJSONObject(index).optString("url");
                            a.toast("正在读取子仓库…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            Cms.Config selected =
                                                    Cms.parseConfig(
                                                            SourceController.fetchImport(a, url),
                                                            url);
                                            String combined =
                                                    com.pilipala.source.Warehouse.retainDirectory(
                                                            selected.raw,
                                                            selected.origin,
                                                            previous.raw,
                                                            raw ->
                                                                    new org.json.JSONObject(
                                                                            Cms.withoutComments(
                                                                                    raw)));
                                            Cms.Config ready =
                                                    Cms.parseConfig(combined, selected.origin);
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing() || a.config != previous)
                                                            return;
                                                        try {
                                                            SourceController.saveConfig(
                                                                    a, ready, ready.origin);
                                                        } catch (Exception e) {
                                                            a.notice("子仓库保存失败，请重试");
                                                        }
                                                    });
                                        } catch (Exception e) {
                                            a.ui.post(
                                                    () -> {
                                                        if (!a.isFinishing())
                                                            a.notice("子仓库读取失败，已保留原线路");
                                                    });
                                        }
                                    });
                        })
                .show();
    }
}
