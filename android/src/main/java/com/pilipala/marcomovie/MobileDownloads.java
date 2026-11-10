package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Phone and tablet download screens: the episode picker opened from the mobile detail page and
 * the live download list under 我的 → 我的下载. The TV interface never shows these views.
 */
final class MobileDownloads {
    private final MainActivity a;
    private final DownloadManager manager;
    private final LinearLayout holder;
    private final Map<String, Row> rows = new HashMap<>();
    private final int ticket;
    private String signature = "";

    private static final class Row {
        TextView status;
        View fill;
        View rest;
    }

    private MobileDownloads(MainActivity activity, LinearLayout parent) {
        a = activity;
        manager = DownloadManager.get(activity);
        holder = activity.vertical();
        ticket = activity.generation;
        parent.addView(holder, new LinearLayout.LayoutParams(-1, -2));
    }

    /** Renders the download list into the 我的 tab and keeps it refreshed while visible. */
    static void render(MainActivity a, LinearLayout parent) {
        if (a.privateMode) {
            parent.addView(a.text("隐私空间不保存下载记录，退出后可查看公开下载。", 15, MainActivity.MUTED));
            return;
        }
        MobileDownloads view = new MobileDownloads(a, parent);
        view.rebuild();
        a.ui.postDelayed(view::tick, 1000);
    }

    private void tick() {
        if (ticket != a.generation || !holder.isAttachedToWindow() || a.isFinishing()) return;
        if (a.foreground) update();
        a.ui.postDelayed(this::tick, 1000);
    }

    private void update() {
        List<DownloadManager.Task> tasks = manager.snapshot();
        if (!signature(tasks).equals(signature)) {
            rebuild();
            return;
        }
        for (DownloadManager.Task t : tasks) {
            Row row = rows.get(t.id);
            if (row != null) bind(row, t);
        }
    }

    private static String signature(List<DownloadManager.Task> tasks) {
        StringBuilder out = new StringBuilder();
        for (DownloadManager.Task t : tasks) {
            out.append(t.id).append(':').append(t.state).append(';');
        }
        return out.toString();
    }

    private void rebuild() {
        holder.removeAllViews();
        rows.clear();
        List<DownloadManager.Task> tasks = manager.snapshot();
        signature = signature(tasks);
        holder.addView(toolbar(tasks), new LinearLayout.LayoutParams(-1, -2));
        a.gap(holder, 10);
        if (tasks.isEmpty()) {
            TextView hint = a.text("还没有下载任务\n在影片详情页点击「⬇ 下载」即可离线保存", 14, MainActivity.MUTED);
            hint.setGravity(Gravity.CENTER);
            hint.setLineSpacing(a.dp(4), 1f);
            hint.setPadding(a.dp(20), a.dp(40), a.dp(20), a.dp(40));
            holder.addView(hint, new LinearLayout.LayoutParams(-1, -2));
        } else {
            for (int i = tasks.size() - 1; i >= 0; i--) {
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                lp.bottomMargin = a.dp(8);
                holder.addView(item(tasks.get(i)), lp);
            }
        }
        TextView where = a.text("保存位置：" + manager.folderPath(), 11, 0xff6b7280);
        where.setPadding(a.dp(4), a.dp(8), a.dp(4), a.dp(16));
        holder.addView(where, new LinearLayout.LayoutParams(-1, -2));
    }

    private View toolbar(List<DownloadManager.Task> tasks) {
        int active = 0;
        int done = 0;
        for (DownloadManager.Task t : tasks) {
            if (t.state == DownloadManager.RUNNING || t.state == DownloadManager.WAITING) active++;
            if (t.state == DownloadManager.DONE) done++;
        }
        LinearLayout bar = a.row();
        String label = "共 " + tasks.size() + " 项 · 进行中 " + active + " · 已完成 " + done;
        TextView summary = a.text(label, 12, MainActivity.MUTED);
        summary.setSingleLine(true);
        summary.setEllipsize(TextUtils.TruncateAt.END);
        bar.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));
        if (tasks.isEmpty()) return bar;
        TextView startAll = chip("全部开始", 0xff8ab4f8);
        startAll.setTag("downloads-start-all");
        startAll.setOnClickListener(
                v -> {
                    manager.resumeAll();
                    update();
                });
        bar.addView(startAll);
        TextView pauseAll = chip("全部暂停", 0xff8ab4f8);
        pauseAll.setTag("downloads-pause-all");
        pauseAll.setOnClickListener(
                v -> {
                    manager.pauseAll();
                    update();
                });
        LinearLayout.LayoutParams pauseLp = new LinearLayout.LayoutParams(-2, -2);
        pauseLp.leftMargin = a.dp(8);
        bar.addView(pauseAll, pauseLp);
        return bar;
    }

    private TextView chip(String label, int color) {
        TextView chip = a.text(label, 12, color);
        chip.setGravity(Gravity.CENTER);
        chip.setSingleLine(true);
        chip.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
        chip.setBackground(a.bg(0xff252734, 14));
        MobileDetailScreen.bindTouchFeedback(chip);
        return chip;
    }

    private View item(DownloadManager.Task t) {
        LinearLayout row = a.row();
        row.setTag("download:" + t.id);
        row.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
        row.setBackground(a.bg(0xff181922, 14));
        MobileDetailScreen.bindTouchFeedback(row);
        row.setOnClickListener(v -> primary(t));

        ImageView thumb = new ImageView(a);
        thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);
        thumb.setBackground(a.bg(0xff252734, 8));
        thumb.setClipToOutline(true);
        LinearLayout.LayoutParams thumbLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(72));
        thumbLp.rightMargin = a.dp(12);
        row.addView(thumb, thumbLp);
        if (!t.poster.isEmpty()) a.poster(t.poster, thumb);

        LinearLayout info = a.vertical();
        TextView title = a.text(t.title, 15, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        info.addView(title);
        String detail = t.line.isEmpty() ? t.episode : t.episode + " · " + t.line;
        TextView sub = a.text(detail, 12, 0xffb4b6c2);
        sub.setSingleLine(true);
        sub.setEllipsize(TextUtils.TruncateAt.END);
        sub.setPadding(0, a.dp(3), 0, 0);
        info.addView(sub);

        Row holderRow = new Row();
        LinearLayout track = a.row();
        track.setBackground(a.bg(0xff2a2c38, 2));
        LinearLayout.LayoutParams trackLp = new LinearLayout.LayoutParams(-1, a.dp(4));
        trackLp.topMargin = a.dp(8);
        info.addView(track, trackLp);
        holderRow.fill = new View(a);
        holderRow.rest = new View(a);
        track.addView(holderRow.fill, new LinearLayout.LayoutParams(0, -1, 0f));
        track.addView(holderRow.rest, new LinearLayout.LayoutParams(0, -1, 100f));
        holderRow.status = a.text("", 12, MainActivity.MUTED);
        holderRow.status.setMaxLines(2);
        holderRow.status.setEllipsize(TextUtils.TruncateAt.END);
        holderRow.status.setPadding(0, a.dp(6), 0, 0);
        info.addView(holderRow.status);
        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1));

        LinearLayout actions = a.vertical();
        TextView main = chip(actionLabel(t.state), 0xff8ab4f8);
        main.setTag("download-action:" + t.id);
        main.setOnClickListener(v -> primary(t));
        actions.addView(main, new LinearLayout.LayoutParams(-1, -2));
        TextView remove = chip("删除", 0xffef4444);
        remove.setTag("download-delete:" + t.id);
        remove.setOnClickListener(v -> confirmDelete(t));
        LinearLayout.LayoutParams removeLp = new LinearLayout.LayoutParams(-1, -2);
        removeLp.topMargin = a.dp(6);
        actions.addView(remove, removeLp);
        LinearLayout.LayoutParams actionsLp = new LinearLayout.LayoutParams(-2, -2);
        actionsLp.leftMargin = a.dp(10);
        row.addView(actions, actionsLp);

        rows.put(t.id, holderRow);
        bind(holderRow, t);
        return row;
    }

    private static String actionLabel(int state) {
        if (state == DownloadManager.DONE) return "▶ 播放";
        if (state == DownloadManager.FAILED) return "重试";
        if (state == DownloadManager.PAUSED) return "继续";
        return "暂停";
    }

    private void bind(Row row, DownloadManager.Task t) {
        int state = t.state;
        row.status.setText(t.status());
        row.status.setTextColor(statusColor(state));
        float done = Math.max(0, t.percent());
        weight(row.fill, done);
        weight(row.rest, 100f - done);
        row.fill.setBackground(a.bg(barColor(state), 2));
    }

    private static int statusColor(int state) {
        if (state == DownloadManager.FAILED) return 0xffef4444;
        if (state == DownloadManager.DONE) return 0xff22c55e;
        if (state == DownloadManager.RUNNING) return 0xff8ab4f8;
        return MainActivity.MUTED;
    }

    private static int barColor(int state) {
        if (state == DownloadManager.FAILED) return 0xffef4444;
        if (state == DownloadManager.DONE) return 0xff22c55e;
        if (state == DownloadManager.PAUSED) return 0xff6b7280;
        return 0xff3b82f6;
    }

    private static void weight(View view, float value) {
        LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) view.getLayoutParams();
        if (lp.weight == value) return;
        lp.weight = value;
        view.setLayoutParams(lp);
    }

    private void primary(DownloadManager.Task t) {
        int state = t.state;
        if (state == DownloadManager.DONE) {
            play(a, t);
            return;
        }
        if (state == DownloadManager.RUNNING || state == DownloadManager.WAITING) {
            manager.pause(t.id);
        } else {
            manager.resume(t.id);
        }
        update();
    }

    private void confirmDelete(DownloadManager.Task t) {
        String name = t.title + " " + t.episode;
        new AppDialog.Builder(a)
                .setTitle("删除下载？")
                .setMessage("将删除「" + name + "」以及已下载的文件。")
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "删除",
                        (dialog, which) -> {
                            manager.delete(t.id);
                            update();
                        })
                .show();
    }

    /** Plays a finished download offline through the regular player page. */
    static void play(MainActivity a, DownloadManager.Task t) {
        File file = t.path.isEmpty() ? null : new File(t.path);
        if (file == null || !file.isFile()) {
            a.toast("下载文件不存在，可能已被删除");
            return;
        }
        a.activeLine = null;
        a.activeEpisode = null;
        a.resumeAt = 0;
        Cms.Site site = new Cms.Site();
        site.key = "download";
        site.name = "本地下载";
        site.api = "";
        site.playUrl = "";
        Cms.Video video = new Cms.Video();
        video.id = "";
        video.title = t.episode.isEmpty() ? t.title : t.title + " · " + t.episode;
        video.poster = t.poster;
        Cms.Episode episode = new Cms.Episode();
        episode.name = t.episode;
        episode.url = Uri.fromFile(file).toString();
        Runnable render = () -> a.playerPage(site, video, episode);
        MainActivity.Screen screen = new MainActivity.Screen(render);
        screen.player = true;
        a.open(screen, true);
    }

    // =========================================================================
    // Episode picker (mobile detail page)
    // =========================================================================

    /** Lets the user pick episodes of one line; {@code current} is preselected. */
    static void pick(MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, String current) {
        int total = line.episodes.size();
        if (total == 0) return;
        boolean[] chosen = new boolean[total];
        int initial = 0;
        for (int i = 0; i < total; i++) {
            if (line.episodes.get(i).name.equals(current)) initial = i;
        }
        chosen[initial] = true;
        TextView[] cells = new TextView[total];

        LinearLayout panel = a.vertical();
        LinearLayout tools = a.row();
        TextView summary = a.text("", 13, MainActivity.WHITE);
        tools.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));
        TextView all = pickerChip(a, "全选");
        tools.addView(all);
        TextView none = pickerChip(a, "清空");
        LinearLayout.LayoutParams noneLp = new LinearLayout.LayoutParams(-2, -2);
        noneLp.leftMargin = a.dp(8);
        tools.addView(none, noneLp);
        panel.addView(tools, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        float widthDp = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        int cols = widthDp >= 640 ? 6 : widthDp >= 480 ? 4 : 3;
        LinearLayout grid = a.vertical();
        panel.addView(grid, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout rowView = null;
        for (int i = 0; i < total; i++) {
            if (i % cols == 0) {
                rowView = a.row();
                grid.addView(rowView, new LinearLayout.LayoutParams(-1, -2));
            }
            final int index = i;
            TextView cell = a.text(line.episodes.get(i).name, 13, 0xffe4e4e7);
            cell.setTag("download-pick:" + i);
            cell.setGravity(Gravity.CENTER);
            cell.setSingleLine(true);
            cell.setEllipsize(TextUtils.TruncateAt.END);
            cell.setPadding(a.dp(6), a.dp(9), a.dp(6), a.dp(9));
            MobileDetailScreen.bindTouchFeedback(cell);
            cell.setOnClickListener(
                    view -> {
                        chosen[index] = !chosen[index];
                        styleCell(a, cells[index], chosen[index]);
                        summary.setText(summaryText(chosen));
                    });
            styleCell(a, cell, chosen[i]);
            cells[i] = cell;
            LinearLayout.LayoutParams cellLp = new LinearLayout.LayoutParams(0, -2, 1);
            cellLp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
            rowView.addView(cell, cellLp);
        }
        int rem = total % cols;
        if (rem > 0 && rowView != null) {
            for (int i = rem; i < cols; i++) {
                LinearLayout.LayoutParams blankLp = new LinearLayout.LayoutParams(0, 1, 1);
                blankLp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
                rowView.addView(new View(a), blankLp);
            }
        }
        summary.setText(summaryText(chosen));
        all.setOnClickListener(
                view -> {
                    for (int i = 0; i < total; i++) {
                        chosen[i] = true;
                        styleCell(a, cells[i], true);
                    }
                    summary.setText(summaryText(chosen));
                });
        none.setOnClickListener(
                view -> {
                    for (int i = 0; i < total; i++) {
                        chosen[i] = false;
                        styleCell(a, cells[i], false);
                    }
                    summary.setText(summaryText(chosen));
                });

        new AppDialog.Builder(a)
                .setTitle("下载 · " + line.name)
                .setView(panel)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "开始下载",
                        (dialog, which) -> {
                            List<Cms.Episode> picked = new ArrayList<>();
                            for (int i = 0; i < total; i++) {
                                if (chosen[i]) picked.add(line.episodes.get(i));
                            }
                            enqueue(a, s, v, line, picked);
                        })
                .show();
    }

    private static TextView pickerChip(MainActivity a, String label) {
        TextView chip = a.text(label, 12, 0xff8ab4f8);
        chip.setGravity(Gravity.CENTER);
        chip.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
        chip.setBackground(a.bg(0xff252734, 14));
        MobileDetailScreen.bindTouchFeedback(chip);
        return chip;
    }

    private static void styleCell(MainActivity a, TextView cell, boolean selected) {
        cell.setTextColor(selected ? Color.WHITE : 0xffe4e4e7);
        cell.setBackground(a.bg(selected ? 0xff3b82f6 : 0xff252734, 10));
    }

    private static String summaryText(boolean[] chosen) {
        int count = 0;
        for (boolean value : chosen) {
            if (value) count++;
        }
        return "已选 " + count + " / " + chosen.length + " 集";
    }

    /** Queues episodes for download and reports the result with a toast. */
    static void enqueue(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, List<Cms.Episode> picked) {
        if (picked.isEmpty()) {
            a.toast("请至少选择一集");
            return;
        }
        if (a.privateMode) {
            a.toast("隐私空间不加入公共下载列表");
            return;
        }
        int added = DownloadManager.get(a).enqueue(s, v, line, picked);
        int skipped = picked.size() - added;
        if (added == 0) {
            a.toast("所选剧集已在下载列表中");
            return;
        }
        String extra = skipped > 0 ? "（" + skipped + " 集已存在）" : "";
        a.toast("已加入下载 " + added + " 集" + extra + "，可在「我的 → 我的下载」查看");
    }
}
