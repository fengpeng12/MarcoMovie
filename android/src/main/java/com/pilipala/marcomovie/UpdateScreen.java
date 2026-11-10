// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.*;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import java.util.Locale;

/**
 * iOS Software Update (`通用 -> 软件更新`) inspired update center for Android Mobile and Android TV.
 * Prioritizes the mirror station for both metadata feeds and APK packages with automatic GitHub
 * fallback and SHA-256 + signature verification before installation.
 */
final class UpdateScreen {
    static final int INSTALL = 1401;
    final MainActivity a;
    final UpdateManager updates;
    TextView status;
    private TextView heroVersionTitle;
    private TextView heroMetaSubtitle;
    private TextView notesHeading;
    private TextView notesBody;
    private View progressWrap;
    private View progressFill;
    private TextView progressPercentView;
    private Button primaryBtn;
    private Button secondaryActionBtn;
    private TextView modeValueView;

    UpdateScreen(MainActivity host) {
        a = host;
        updates = UpdateManager.get(a);
    }

    private GradientDrawable cardSurface(
            int topColor, int bottomColor, float radiusDp, int stroke) {
        GradientDrawable d =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM, new int[] {topColor, bottomColor});
        d.setCornerRadius(a.dp(radiusDp));
        if (stroke != 0) {
            d.setStroke(Math.max(1, a.dp(0.8f)), stroke);
        }
        return d;
    }

    void show() {
        a.renderPage("", "");
        a.updateScreen = this;
        boolean tv = a.isTvDevice();

        // Top Navigation Bar
        if (!tv) {
            LinearLayout topNav = a.row();
            topNav.setGravity(Gravity.CENTER_VERTICAL);
            topNav.setPadding(0, 0, 0, a.dp(14));
            TextView backBtn = a.text("‹", 22, MainActivity.WHITE);
            backBtn.setGravity(Gravity.CENTER);
            backBtn.setBackground(
                    MobileShell.glassBg(0xb034343a, 0xc01e1e22, a.dp(999), a.dp(0.8f), 0x38ffffff));
            MobileDetailScreen.bindTouchFeedback(backBtn);
            backBtn.setOnClickListener(v -> a.onBackPressed());
            LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
            backLp.rightMargin = a.dp(12);
            topNav.addView(backBtn, backLp);

            TextView heading = a.text("软件更新", 22, MainActivity.WHITE);
            heading.setTypeface(null, Typeface.BOLD);
            topNav.addView(heading, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView mirrorBadge = a.text("镜像站优先", 11.5f, 0xff34d399);
            mirrorBadge.setTypeface(null, Typeface.BOLD);
            mirrorBadge.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
            mirrorBadge.setBackground(cardSurface(0x2630d158, 0x1a30d158, 999, 0x5534d399));
            topNav.addView(mirrorBadge, new LinearLayout.LayoutParams(-2, -2));
            a.body.addView(topNav, new LinearLayout.LayoutParams(-1, -2));
        } else {
            LinearLayout titleRow = a.row();
            titleRow.setGravity(Gravity.CENTER_VERTICAL);
            TextView heading = a.text("软件更新", 28, MainActivity.WHITE);
            heading.setTypeface(null, Typeface.BOLD);
            titleRow.addView(heading, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView mirrorBadge = a.text("镜像站优先 · 自动校验签名", 12.5f, 0xff34d399);
            mirrorBadge.setTypeface(null, Typeface.BOLD);
            mirrorBadge.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
            mirrorBadge.setBackground(cardSurface(0x2630d158, 0x1a30d158, 999, 0x5534d399));
            titleRow.addView(mirrorBadge, new LinearLayout.LayoutParams(-2, -2));
            a.body.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));
            a.gap(a.body, 14);
        }

        // =====================================================================
        // 1. iOS SOFTWARE UPDATE HERO CARD
        // =====================================================================
        LinearLayout heroCard = a.vertical();
        heroCard.setPadding(a.dp(20), a.dp(20), a.dp(20), a.dp(20));
        heroCard.setBackground(cardSurface(0xd81c2421, 0xe6121816, 24, 0x2effffff));

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);

        // iOS App Squircle Icon Badge
        FrameLayout iconBox = new FrameLayout(a);
        GradientDrawable squircle =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR,
                        new int[] {0xff1f4739, 0xff0f241d, 0xff091512});
        squircle.setCornerRadius(a.dp(16));
        squircle.setStroke(Math.max(1, a.dp(1)), 0x485ac8fa);
        iconBox.setBackground(squircle);
        ImageView logo = new ImageView(a);
        logo.setImageResource(R.drawable.logo_mark);
        FrameLayout.LayoutParams logoLp =
                new FrameLayout.LayoutParams(a.dp(36), a.dp(36), Gravity.CENTER);
        iconBox.addView(logo, logoLp);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(60), a.dp(60));
        iconLp.rightMargin = a.dp(16);
        headerRow.addView(iconBox, iconLp);

        LinearLayout titleCol = a.vertical();
        heroVersionTitle =
                a.text("Marco Movie " + UpdateManager.installedVersion(a), 19, MainActivity.WHITE);
        heroVersionTitle.setTypeface(null, Typeface.BOLD);
        titleCol.addView(heroVersionTitle);

        heroMetaSubtitle =
                a.text((tv ? "Android TV 端" : "Android 手机端") + " · 正式版渠道", 12.5f, 0xff9ca3af);
        heroMetaSubtitle.setPadding(0, a.dp(3), 0, 0);
        titleCol.addView(heroMetaSubtitle);

        status = a.text("", 13f, 0xff34d399);
        status.setTag("update-status");
        status.setPadding(0, a.dp(5), 0, 0);
        status.setLineSpacing(a.dp(2), 1f);
        titleCol.addView(status);

        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        heroCard.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        // Sleek iOS Download Progress Bar (shown when downloading / verifying)
        LinearLayout progContainer = a.vertical();
        progContainer.setPadding(0, a.dp(16), 0, 0);
        LinearLayout progLabelRow = a.row();
        progLabelRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView progTitle = a.text("正在优先从镜像站传输安装包…", 12, MainActivity.MUTED);
        progLabelRow.addView(progTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        progressPercentView = a.text("0%", 12, 0xff5ac8fa);
        progressPercentView.setTypeface(null, Typeface.BOLD);
        progLabelRow.addView(progressPercentView, new LinearLayout.LayoutParams(-2, -2));
        progContainer.addView(progLabelRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(progContainer, 6);

        FrameLayout track = new FrameLayout(a);
        track.setBackground(a.bg(0x33ffffff, 999));
        progressFill = new View(a);
        progressFill.setBackground(a.bg(0xff0a84ff, 999));
        track.addView(progressFill, new FrameLayout.LayoutParams(0, a.dp(6), Gravity.LEFT));
        progContainer.addView(track, new LinearLayout.LayoutParams(-1, a.dp(6)));
        progressWrap = progContainer;
        progressWrap.setVisibility(View.GONE);
        heroCard.addView(progressWrap, new LinearLayout.LayoutParams(-1, -2));

        // Hairline Divider
        a.gap(heroCard, 16);
        View divider = new View(a);
        divider.setBackgroundColor(0x1fffffff);
        heroCard.addView(divider, new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.7f))));
        a.gap(heroCard, 14);

        // Release Notes / Feature Highlights Box
        notesHeading = a.text("关于此更新", 13.5f, MainActivity.WHITE);
        notesHeading.setTypeface(null, Typeface.BOLD);
        heroCard.addView(notesHeading);
        a.gap(heroCard, 6);

        notesBody = a.text("", 13f, 0xffd1d5db);
        notesBody.setLineSpacing(a.dp(4), 1f);
        heroCard.addView(notesBody, new LinearLayout.LayoutParams(-1, -2));

        a.gap(heroCard, 18);

        // Primary & Secondary Action Buttons Row
        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        primaryBtn =
                a.button(
                        "检查软件更新",
                        "update-check",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else if (updates.ready()) {
                                install();
                            } else if (updates.available != null) {
                                updates.download();
                            } else {
                                updates.check(true);
                            }
                        });
        primaryBtn.setFocusable(true);
        primaryBtn.setTextSize(14.5f);
        primaryBtn.setTypeface(null, Typeface.BOLD);
        primaryBtn.setTextColor(MainActivity.WHITE);
        primaryBtn.setMinHeight(a.dp(46));
        primaryBtn.setMinimumHeight(a.dp(46));
        primaryBtn.setBackground(a.bg(0xff0a84ff, 14));
        primaryBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                primaryBtn,
                                f,
                                0xff0a84ff,
                                MainActivity.WHITE,
                                14,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.02f));
        actionRow.addView(primaryBtn, new LinearLayout.LayoutParams(0, a.dp(46), 1f));

        secondaryActionBtn =
                a.button(
                        "重新检查",
                        "update-secondary",
                        () -> {
                            if (updates.busy) {
                                updates.cancel();
                            } else {
                                updates.check(true);
                            }
                        });
        secondaryActionBtn.setFocusable(true);
        secondaryActionBtn.setTextSize(13.5f);
        secondaryActionBtn.setTextColor(0xffe5e7eb);
        secondaryActionBtn.setMinHeight(a.dp(46));
        secondaryActionBtn.setMinimumHeight(a.dp(46));
        secondaryActionBtn.setPadding(a.dp(16), 0, a.dp(16), 0);
        secondaryActionBtn.setBackground(cardSurface(0xff26312d, 0xff1c2522, 14, 0x2effffff));
        secondaryActionBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                secondaryActionBtn,
                                f,
                                0xff26312d,
                                MainActivity.WHITE,
                                14,
                                0xffe5e7eb,
                                MainActivity.DARK,
                                false,
                                1.02f));
        LinearLayout.LayoutParams secLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        secLp.leftMargin = a.dp(10);
        actionRow.addView(secondaryActionBtn, secLp);

        heroCard.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));
        a.body.addView(heroCard, new LinearLayout.LayoutParams(-1, -2));

        a.gap(a.body, 16);

        // =====================================================================
        // 2. iOS INSET-GROUPED SETTINGS CARD (Automatic Updates & Mirror Policy)
        // =====================================================================
        LinearLayout groupCard = a.vertical();
        groupCard.setBackground(cardSurface(0xb81b2320, 0xb8131917, 20, 0x26ffffff));

        // Row 1: Automatic Update Mode
        LinearLayout modeRow = a.row();
        modeRow.setTag("update-mode");
        modeRow.setGravity(Gravity.CENTER_VERTICAL);
        modeRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        modeRow.setClickable(true);
        modeRow.setFocusable(tv);
        modeRow.setFocusableInTouchMode(tv);
        if (tv) {
            modeRow.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    modeRow,
                                    f,
                                    0x00000000,
                                    0x28ffffff,
                                    16,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    true,
                                    1.005f));
        } else {
            MobileShell.bindCardTouchFeedback(
                    a, modeRow, null, cardSurface(0x28ffffff, 0x18ffffff, 20, 0));
        }
        TextView modeTitle = a.text("自动更新策略", 15f, MainActivity.WHITE);
        modeTitle.setTypeface(null, Typeface.BOLD);
        modeRow.addView(modeTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        modeValueView = a.text(modeName(updates.mode()) + "  ›", 13.5f, MainActivity.MUTED);
        modeRow.addView(modeValueView, new LinearLayout.LayoutParams(-2, -2));
        modeRow.setOnClickListener(
                v -> {
                    if (!tv) {
                        String[] modes = {"notify", "download", "off"};
                        String[] labels = {"自动检查并提醒（推荐）", "自动下载后提醒", "仅手动检查"};
                        int cur =
                                Math.max(0, java.util.Arrays.asList(modes).indexOf(updates.mode()));
                        MobileShell.showDrawerPicker(
                                a,
                                "自动更新策略",
                                "自动检查至少间隔六小时，播放过程中绝不弹窗打扰",
                                labels,
                                cur,
                                idx -> {
                                    updates.setMode(modes[idx]);
                                    refresh();
                                });
                    } else {
                        mode();
                    }
                });
        groupCard.addView(modeRow, new LinearLayout.LayoutParams(-1, -2));

        View rowDiv1 = new View(a);
        rowDiv1.setBackgroundColor(0x16ffffff);
        LinearLayout.LayoutParams divLp1 =
                new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.6f)));
        divLp1.leftMargin = a.dp(18);
        divLp1.rightMargin = a.dp(18);
        groupCard.addView(rowDiv1, divLp1);

        // Row 2: Manual Install Ready Package (if downloaded) or Release Notes Dialog
        LinearLayout installRow = a.row();
        installRow.setTag("update-install");
        installRow.setGravity(Gravity.CENTER_VERTICAL);
        installRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        installRow.setClickable(true);
        installRow.setFocusable(tv);
        installRow.setFocusableInTouchMode(tv);
        if (tv) {
            installRow.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    installRow,
                                    f,
                                    0x00000000,
                                    0x28ffffff,
                                    16,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    true,
                                    1.005f));
        } else {
            MobileShell.bindCardTouchFeedback(
                    a, installRow, null, cardSurface(0x28ffffff, 0x18ffffff, 20, 0));
        }
        TextView installTitle = a.text("安装已下载更新包", 15f, MainActivity.WHITE);
        installTitle.setTypeface(null, Typeface.BOLD);
        installRow.addView(installTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView installHint = a.text("覆盖升级保留全部数据  ›", 13f, MainActivity.MUTED);
        installRow.addView(installHint, new LinearLayout.LayoutParams(-2, -2));
        installRow.setOnClickListener(v -> install());
        groupCard.addView(installRow, new LinearLayout.LayoutParams(-1, -2));

        View rowDiv2 = new View(a);
        rowDiv2.setBackgroundColor(0x16ffffff);
        LinearLayout.LayoutParams divLp2 =
                new LinearLayout.LayoutParams(-1, Math.max(1, a.dp(0.6f)));
        divLp2.leftMargin = a.dp(18);
        divLp2.rightMargin = a.dp(18);
        groupCard.addView(rowDiv2, divLp2);

        // Row 3: Mirror Source Priority Info
        LinearLayout sourceRow = a.row();
        sourceRow.setGravity(Gravity.CENTER_VERTICAL);
        sourceRow.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        TextView sourceTitle = a.text("下载线路优先级", 15f, MainActivity.WHITE);
        sourceTitle.setTypeface(null, Typeface.BOLD);
        sourceRow.addView(sourceTitle, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView sourceVal = a.text("镜像站优先 · GitHub 备用", 13f, 0xff34d399);
        sourceRow.addView(sourceVal, new LinearLayout.LayoutParams(-2, -2));
        groupCard.addView(sourceRow, new LinearLayout.LayoutParams(-1, -2));

        a.body.addView(groupCard, new LinearLayout.LayoutParams(-1, -2));

        a.gap(a.body, 14);
        TextView footer =
                a.text(
                        "各平台版本独立推进。检查更新与下载安装包均优先连接镜像站（marcotv.wlj9919.top），不可用时自动无缝回退至 GitHub 官方源。安装前自动核验 SHA-256 摘要与开发者签名。",
                        12f,
                        MainActivity.MUTED);
        footer.setPadding(a.dp(6), 0, a.dp(6), a.dp(16));
        footer.setLineSpacing(a.dp(3), 1f);
        a.body.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        refresh();
    }

    void refresh() {
        String installedVer = UpdateManager.installedVersion(a);
        boolean tv = a.isTvDevice();
        String platformLabel = tv ? "Android TV 端" : "Android 手机端";
        UpdateManager.Release rel = updates.available;

        if (status != null) {
            status.setText(
                    "当前版本 "
                            + installedVer
                            + " · 正式版\n"
                            + updates.message
                            + (updates.percent >= 0 ? " · " + updates.percent + "%" : "")
                            + "\n"
                            + modeName(updates.mode()));
            if (updates.ready() || (rel == null && !updates.busy)) {
                status.setTextColor(0xff34d399);
            } else if (updates.busy) {
                status.setTextColor(0xff5ac8fa);
            } else {
                status.setTextColor(0xfffbbf24);
            }
        }

        if (heroVersionTitle != null) {
            if (rel != null) {
                heroVersionTitle.setText("Marco Movie " + rel.version);
            } else {
                heroVersionTitle.setText("Marco Movie " + installedVer);
            }
        }

        if (heroMetaSubtitle != null) {
            if (rel != null && rel.size > 0) {
                String sizeMb = String.format(Locale.US, "%.1f MB", rel.size / (1024f * 1024f));
                heroMetaSubtitle.setText(platformLabel + " · 新版本可用 · " + sizeMb);
            } else {
                heroMetaSubtitle.setText(platformLabel + " · 已安装当前版本 " + installedVer);
            }
        }

        if (progressWrap != null && progressFill != null && progressPercentView != null) {
            if (updates.busy && updates.percent >= 0) {
                progressWrap.setVisibility(View.VISIBLE);
                int pct = Math.max(0, Math.min(100, updates.percent));
                progressPercentView.setText(pct + "%");
                View parent = (View) progressFill.getParent();
                int totalW =
                        parent != null && parent.getWidth() > 0
                                ? parent.getWidth()
                                : (a.windowWidth() - a.dp(80));
                FrameLayout.LayoutParams lp =
                        (FrameLayout.LayoutParams) progressFill.getLayoutParams();
                lp.width = Math.max(a.dp(8), Math.round(totalW * (pct / 100f)));
                progressFill.setLayoutParams(lp);
            } else {
                progressWrap.setVisibility(View.GONE);
            }
        }

        if (notesHeading != null && notesBody != null) {
            if (rel != null && rel.notes != null && !rel.notes.trim().isEmpty()) {
                notesHeading.setText("版本 " + rel.version + " 更新内容");
                notesBody.setText(rel.notes.trim());
            } else {
                notesHeading.setText("版本特性与安全保障");
                notesBody.setText(
                        "• 镜像站优先加速：检查更新与下载 APK 均优先拉取镜像站资源，异常时自动切换 GitHub\n"
                                + "• 平台独立演进：手机端与电视端按各自平台节奏独立发布版本号\n"
                                + "• 完整性与签名保护：安装前严格校验 SHA-256 与应用签名，覆盖升级保留全部片源配置与历史记录");
            }
        }

        if (primaryBtn != null && secondaryActionBtn != null) {
            if (updates.busy) {
                primaryBtn.setText("正在处理… 取消任务");
                secondaryActionBtn.setVisibility(View.GONE);
            } else if (updates.ready() && rel != null) {
                primaryBtn.setText("现在安装 " + rel.version);
                secondaryActionBtn.setText("重新检查");
                secondaryActionBtn.setVisibility(View.VISIBLE);
            } else if (rel != null) {
                primaryBtn.setText("下载并更新 (" + rel.version + ")");
                secondaryActionBtn.setText("重新检查");
                secondaryActionBtn.setVisibility(View.VISIBLE);
            } else {
                primaryBtn.setText("检查软件更新");
                secondaryActionBtn.setVisibility(View.GONE);
            }
        }

        if (modeValueView != null) {
            modeValueView.setText(modeName(updates.mode()) + "  ›");
        }
    }

    static String modeName(String mode) {
        return "off".equals(mode) ? "仅手动检查" : "download".equals(mode) ? "自动下载后提醒" : "自动检查并提醒";
    }

    void mode() {
        String[] modes = {"notify", "download", "off"};
        new AppDialog.Builder(a)
                .setTitle("更新方式")
                .setMessage("自动检查至少间隔六小时，仅在应用首页运行时发起。播放过程中不弹出更新窗口；安装始终由你确认。")
                .setSingleChoiceItems(
                        new String[] {"自动检查并提醒", "自动下载后提醒", "仅手动检查"},
                        java.util.Arrays.asList(modes).indexOf(updates.mode()),
                        (d, n) -> {
                            updates.setMode(modes[n]);
                            refresh();
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    void install() {
        if (updates.busy) {
            a.toast("请等待当前任务完成");
            return;
        }
        if (!updates.ready()) {
            a.toast("请先下载并校验新版");
            return;
        }
        String deviceName = a.isTvDevice() ? "电视" : "手机";
        if (Build.VERSION.SDK_INT >= 26 && !a.getPackageManager().canRequestPackageInstalls()) {
            new AppDialog.Builder(a)
                    .setTitle("允许安装更新")
                    .setMessage(deviceName + "需要你允许 Marco Movie 安装应用。打开系统授权后，返回本页再次选择安装。")
                    .setPositiveButton(
                            "打开授权页面",
                            (d, n) -> {
                                try {
                                    a.startActivity(
                                            new Intent(
                                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                                    Uri.parse("package:" + a.getPackageName())));
                                } catch (RuntimeException e) {
                                    a.notice("当前设备未提供授权页面，请从设置中开启未知来源安装权限。");
                                }
                            })
                    .setNegativeButton("稍后", null)
                    .show();
            return;
        }
        new AppDialog.Builder(a)
                .setTitle("安装 " + updates.available.version + "？")
                .setMessage("将打开系统的安装确认页面。覆盖升级保留配置、收藏和观看记录。")
                .setPositiveButton("继续安装", (d, n) -> prepareInstall())
                .setNegativeButton("稍后", null)
                .show();
    }

    static Intent installIntent() {
        Intent intent =
                new Intent(Intent.ACTION_INSTALL_PACKAGE)
                        .setDataAndType(
                                UpdateApkProvider.URI, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .putExtra(Intent.EXTRA_RETURN_RESULT, true);
        intent.setClipData(ClipData.newRawUri("Marco Movie update", UpdateApkProvider.URI));
        return intent;
    }

    void prepareInstall() {
        final UpdateManager.Release release = updates.available;
        if (release == null || updates.busy) return;
        final int epoch = a.generation;
        updates.busy = true;
        updates.resetCancellation();
        updates.message = "正在核对安装包…";
        refresh();
        updates.worker.execute(
                () -> {
                    try {
                        UpdateManager.verifyApk(a, updates.apk(), release);
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    if (!a.foreground
                                            || a.isFinishing()
                                            || a.isDestroyed()
                                            || epoch != a.generation
                                            || updates.cancelled()
                                            || status == null
                                            || !status.isAttachedToWindow()) {
                                        updates.message = "校验完成，回到软件更新页后可继续安装";
                                        return;
                                    }
                                    try {
                                        updates.prefs
                                                .edit()
                                                .putInt("pending_code", release.code)
                                                .commit();
                                        a.startActivityForResult(installIntent(), INSTALL);
                                        updates.message = "请在系统安装页面确认或返回";
                                    } catch (RuntimeException error) {
                                        updates.prefs.edit().remove("pending_code").apply();
                                        updates.message = "无法打开安装器，请从官方发布页下载安装";
                                    }
                                    refresh();
                                });
                    } catch (Exception error) {
                        a.ui.post(
                                () -> {
                                    updates.busy = false;
                                    updates.message = "安装包校验失败，请重新下载";
                                    refresh();
                                });
                    }
                });
    }

    static void result(MainActivity a) {
        UpdateManager updates = UpdateManager.get(a);
        updates.prefs.edit().remove("pending_code").apply();
        updates.message = "已返回应用；若取消安装，原版本继续保留";
        if (a.updateScreen != null) a.updateScreen.refresh();
    }
}
