package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;

/**
 * Immersive live-video backdrop detail screen when pressing Back during TV playback.
 *
 * <p>Instead of shrinking the video into an awkward floating rectangle in the middle of the page,
 * keeps the live playing video surface full-bleed across the upper hero backdrop window with a
 * smooth lower gradient transition into the centered hero stage and full-width episode grid.
 */
final class MiniDetails {
    final MainActivity a;
    final FrameLayout page;
    final View hit;
    final PlaybackControls controls;

    MiniDetails(MainActivity host) {
        a = host;
        controls = a.playbackControls;
        final Cms.Video video = controls.video;
        final Cms.Site site = controls.site;

        // Keep the live video surface full-screen at the bottom layer so it acts as the
        // uninterrupted immersive dynamic hero background.
        UiCompat.setClipToOutline(a.playbackLayer, false);
        a.playbackLayer.setBackgroundColor(Color.BLACK);
        a.playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));

        page = new FrameLayout(a);
        page.setTag("mini-details");
        page.setClipChildren(false);
        page.setClipToPadding(false);
        page.setBackgroundColor(Color.TRANSPARENT);

        final LiveVideoScrimView scrim = new LiveVideoScrimView();
        page.addView(scrim, new FrameLayout.LayoutParams(-1, -1));

        // Invisible carrier keeps mini-cover tag & non-overlapping bounds for device probes
        ImmersivePoster cover = new ImmersivePoster(a, "mini-cover");
        cover.immersiveMode = true;
        FrameLayout.LayoutParams coverSize =
                new FrameLayout.LayoutParams(a.dp(260), a.dp(390), Gravity.TOP | Gravity.LEFT);
        coverSize.leftMargin = -a.dp(260);
        page.addView(cover, coverSize);
        cover.load(video.poster, video.title, video.year, video.actor, video.director, false);

        final TvScrollView list = new TvScrollView(a);
        list.setFillViewport(true);
        list.setClipChildren(false);
        list.setClipToPadding(false);
        list.setVerticalScrollBarEnabled(false);
        list.getViewTreeObserver()
                .addOnScrollChangedListener(() -> scrim.setScrollOffset(list.getScrollY()));
        page.addView(list, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout content = a.vertical();
        content.setClipChildren(false);
        content.setClipToPadding(false);
        list.addView(content, new ScrollView.LayoutParams(-1, -2));

        // 1. Top Liquid Glass Navigation Bar (Back on left, Favorite on right)
        LinearLayout topBar = a.row();
        topBar.setClipChildren(false);
        topBar.setClipToPadding(false);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(a.dp(38), a.dp(20), a.dp(38), a.dp(8));

        Button back =
                DetailScreen.glassNavButton(a, "‹ 退出播放", "mini-back", false, a::onBackPressed);
        back.setId(View.generateViewId());
        topBar.addView(back, new LinearLayout.LayoutParams(-2, a.dp(38)));

        View topSpacer = new View(a);
        topBar.addView(topSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        boolean initialFav =
                Favorites.contains(a.prefs.getString(Prefs.FAVORITES, "[]"), site.key, video.id);
        Button favorite =
                DetailScreen.glassNavButton(
                        a, initialFav ? "♥ 已收藏" : "♡ 加入收藏", "mini-favorite", initialFav, () -> {});
        favorite.setId(View.generateViewId());
        back.setNextFocusRightId(favorite.getId());
        favorite.setNextFocusLeftId(back.getId());
        DetailScreen.bindFavoriteAction(a, site, video, favorite);
        topBar.addView(favorite, new LinearLayout.LayoutParams(-2, a.dp(38)));
        content.addView(topBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. Upper Live Video Showcase Window (clicking it also returns to full-screen playback)
        float screenHeightDp = a.windowHeight() / a.getResources().getDisplayMetrics().density;
        int videoShowcaseDp = Math.max(82, Math.min(132, Math.round(screenHeightDp * 0.16f)));
        View videoTouchZone = new View(a);
        videoTouchZone.setFocusable(false);
        videoTouchZone.setOnClickListener(v -> a.expandPlayback());
        content.addView(videoTouchZone, new LinearLayout.LayoutParams(-1, a.dp(videoShowcaseDp)));

        // 3. Centered Hero Stage over the Live Video Gradient Feather Zone
        LinearLayout hero = a.vertical();
        hero.setGravity(Gravity.CENTER_HORIZONTAL);
        hero.setClipChildren(false);
        hero.setClipToPadding(false);
        hero.setPadding(a.dp(48), a.dp(2), a.dp(48), a.dp(8));
        content.addView(hero, new LinearLayout.LayoutParams(-1, -2));

        // Live playing episode badge pill
        String currentEpName =
                controls.resolved != null && controls.resolved.name != null
                        ? controls.resolved.name
                        : (a.activeEpisode != null ? a.activeEpisode.name : "");
        if (!currentEpName.isEmpty()) {
            TextView liveBadge = a.text("● 正在播放 · " + currentEpName, 12, 0xff90caf9);
            liveBadge.setSingleLine(true);
            liveBadge.setEllipsize(TextUtils.TruncateAt.END);
            liveBadge.setMaxWidth(a.dp(620));
            liveBadge.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
            GradientDrawable badgeBg = new GradientDrawable();
            badgeBg.setCornerRadius(a.dp(14));
            badgeBg.setColor(0x88101826);
            badgeBg.setStroke(Math.max(1, a.dp(1)), 0x5564b5f6);
            liveBadge.setBackground(badgeBg);
            LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(-2, -2);
            badgeLp.gravity = Gravity.CENTER_HORIZONTAL;
            badgeLp.bottomMargin = a.dp(6);
            hero.addView(liveBadge, badgeLp);
        }

        TextView title = a.text(video.title, 28, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        title.setGravity(Gravity.CENTER);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(a.dp(12), 0, a.dp(3), 0xcc000000);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(-2, -2);
        titleLp.gravity = Gravity.CENTER_HORIZONTAL;
        hero.addView(title, titleLp);

        LinearLayout metaRow = a.row();
        metaRow.setGravity(Gravity.CENTER);
        List<String> pills = DetailScreen.collectMetaPills(video);
        for (int i = 0; i < pills.size(); i++) {
            TextView pill = DetailScreen.makeGlassMetaPill(a, pills.get(i));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = a.dp(8);
            metaRow.addView(pill, lp);
        }
        if (metaRow.getChildCount() > 0) {
            LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-2, -2);
            metaLp.gravity = Gravity.CENTER_HORIZONTAL;
            metaLp.topMargin = a.dp(7);
            hero.addView(metaRow, metaLp);
        }

        LinearLayout ratingRow = DetailScreen.buildRatingAndCastRow(a, site, video);
        LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-2, -2);
        ratingLp.gravity = Gravity.CENTER_HORIZONTAL;
        ratingLp.topMargin = a.dp(6);
        hero.addView(ratingRow, ratingLp);

        if (video.description != null && !video.description.isEmpty()) {
            LinearLayout synopsisRow = a.vertical();
            synopsisRow.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView synopsis = a.text(video.description, 14, 0xdcebebf5);
            synopsis.setGravity(Gravity.CENTER);
            synopsis.setLineSpacing(a.dp(2), 1.04f);
            synopsis.setMaxLines(2);
            synopsis.setEllipsize(TextUtils.TruncateAt.END);
            synopsis.setMaxWidth(a.dp(760));
            synopsis.setShadowLayer(a.dp(6), 0, a.dp(1), 0x88000000);
            synopsisRow.addView(synopsis, new LinearLayout.LayoutParams(-2, -2));

            Button moreBtn =
                    DetailScreen.glassNavButton(
                            a,
                            "展开完整简介与演职员 ›",
                            "mini-synopsis",
                            false,
                            () ->
                                    new AppDialog.Builder(a)
                                            .setTitle(video.title)
                                            .setMessage(
                                                    DetailScreen.buildFullSynopsisMessage(video))
                                            .setPositiveButton("关闭", null)
                                            .show());
            moreBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            moreBtn.setMinHeight(a.dp(26));
            moreBtn.setMinimumHeight(a.dp(26));
            moreBtn.setPadding(a.dp(12), a.dp(3), a.dp(12), a.dp(3));
            LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-2, a.dp(26));
            moreLp.topMargin = a.dp(4);
            synopsisRow.addView(moreBtn, moreLp);

            LinearLayout.LayoutParams synLp = new LinearLayout.LayoutParams(-2, -2);
            synLp.gravity = Gravity.CENTER_HORIZONTAL;
            synLp.topMargin = a.dp(6);
            hero.addView(synopsisRow, synLp);
        }

        // Centered Prominent White Stadium Button to return to full-screen playback
        Button expand =
                DetailScreen.heroPlayButton(a, "►  返回全屏播放", "mini-expand", a::expandPlayback);
        LinearLayout.LayoutParams expandLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        expandLp.gravity = Gravity.CENTER_HORIZONTAL;
        expandLp.topMargin = a.dp(10);
        hero.addView(expand, expandLp);
        hit = expand;

        // 4. Full-Width Bottom Episode & Line Shelf
        LinearLayout info = a.vertical();
        info.setClipChildren(false);
        info.setClipToPadding(false);
        info.setPadding(a.dp(38), a.dp(4), a.dp(38), a.dp(42));
        content.addView(info, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout seasonPanel = a.vertical();
        seasonPanel.setTag("detail-seasons");
        info.addView(seasonPanel, new LinearLayout.LayoutParams(-1, -2));
        DetailScreen.populateTvRelatedSeasons(a, site, video, seasonPanel);

        LinearLayout episodes = a.vertical();
        episodes.setTag("detail-episodes");
        LinearLayout.LayoutParams epLp = new LinearLayout.LayoutParams(-1, -2);
        epLp.topMargin = a.dp(8);
        info.addView(episodes, epLp);

        if (!video.lines.isEmpty()) {
            int line = Math.max(0, video.lines.indexOf(a.activeLine));
            int index =
                    a.activeLine == null
                            ? 0
                            : Math.max(0, a.activeLine.episodes.indexOf(a.activeEpisode));
            a.renderEpisodes(
                    site,
                    video,
                    line,
                    EpisodeSelection.pageFor(
                            index,
                            video.lines.get(line).episodes.size(),
                            a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false)),
                    episodes);
        } else {
            episodes.addView(a.text("当前内容没有可选择的剧集。", 15, MainActivity.MUTED));
        }

        int layerIdx = a.root.indexOfChild(a.playbackLayer);
        a.root.addView(
                page, layerIdx >= 0 ? layerIdx + 1 : 0, new FrameLayout.LayoutParams(-1, -1));

        a.playbackLayer.post(
                () -> {
                    if (a.miniMode) {
                        controls.resize(controls.videoWidth, controls.videoHeight);
                        hit.requestFocus();
                    }
                });
    }

    void remove() {
        a.root.removeView(page);
        if (hit != null && hit.getParent() == a.playbackLayer) {
            a.playbackLayer.removeView(hit);
        }
        View hint = a.playbackLayer.findViewWithTag("mini-hint");
        if (hint != null) a.playbackLayer.removeView(hint);
    }

    /**
     * Draws a transparent upper showcase window over the live video surface and smoothly feathers
     * it into a solid dark ambient surface for the centered hero controls and bottom episode grid.
     */
    private final class LiveVideoScrimView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private float scrollProgress = 0f;

        LiveVideoScrimView() {
            super(a);
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        }

        void setScrollOffset(int scrollY) {
            int h = getHeight();
            float range = h > 0 ? h * 0.42f : a.dp(240);
            float next = Math.max(0f, Math.min(1f, scrollY / Math.max(1f, range)));
            if (Math.abs(next - scrollProgress) > 0.004f) {
                scrollProgress = next;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas c) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;

            float winH = h * 0.78f;

            // 1. Top floating bar subtle legibility scrim
            paint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            h * 0.16f,
                            new int[] {0x7c000000, 0x28000000, 0x00000000},
                            new float[] {0f, 0.55f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, 0, w, h * 0.16f, paint);
            paint.setShader(null);

            // 2. Smooth feather gradient from transparent live video into solid dark surface
            paint.setShader(
                    new LinearGradient(
                            0,
                            winH * 0.32f,
                            0,
                            winH,
                            new int[] {0x00090c14, 0x58090c14, 0xc8090c14, 0xf2090c14, 0xff090c14},
                            new float[] {0f, 0.34f, 0.68f, 0.88f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, winH * 0.32f, w, winH + 2f, paint);
            paint.setShader(null);

            // 3. Solid dark surface below winH so the episode list has a pure dark background
            paint.setColor(0xff090c14);
            c.drawRect(0, winH, w, h, paint);

            // 4. Scroll-driven veil when user scrolls down into the episode grid
            if (scrollProgress > 0.005f) {
                int alpha = Math.min(232, Math.round(scrollProgress * 232f));
                paint.setColor(Color.argb(alpha, 9, 12, 20));
                c.drawRect(0, 0, w, winH, paint);
            }
        }
    }
}
