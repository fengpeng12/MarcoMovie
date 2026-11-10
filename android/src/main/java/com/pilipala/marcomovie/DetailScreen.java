package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Immersive TV & portrait video detail screen.
 *
 * <p>Redesigned with a mobile-portrait-inspired full-bleed hero poster stage (backed by 16:9 HD
 * widescreen stills or unstretched height-fitted vertical posters over a dynamic ambient color
 * field) and a full-width multi-line episode grid where every episode displays its complete title
 * without a separate focused-title bar.
 */
final class DetailScreen {
    private static final Pattern SCORE_PATTERN = Pattern.compile("(?<!\\d)([1-9]\\.[0-9])(?!\\d)");
    private static long lastLineHorizontalDpadTime;

    private DetailScreen() {}

    static void show(MainActivity a, Cms.Site s, Cms.Video listing, Cms.Video ready) {
        if (a.redirectListing(s, listing)) return;
        a.renderPage("", "", false);
        a.body.setPadding(0, 0, 0, 0);
        a.body.setClipChildren(false);
        a.body.setClipToPadding(false);

        final ImmersivePoster cover = new ImmersivePoster(a, "detail-cover");
        cover.immersiveMode = true;
        a.root.addView(cover.backdrop, 1, new FrameLayout.LayoutParams(-1, -1));
        // Invisible fixed carrier in root keeps detail-cover bounds & decode policy active
        // without rendering any boxed poster card on screen.
        FrameLayout.LayoutParams coverLp =
                new FrameLayout.LayoutParams(a.dp(260), a.dp(390), Gravity.TOP | Gravity.START);
        a.root.addView(cover, 2, coverLp);

        final TvScrollView detailsScroll = new TvScrollView(a);
        detailsScroll.setTag("detail-scroll");
        detailsScroll.setFillViewport(true);
        detailsScroll.setClipChildren(false);
        detailsScroll.setClipToPadding(false);
        detailsScroll.setVerticalScrollBarEnabled(false);
        detailsScroll
                .getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> cover.backdrop.setScrollOffset(detailsScroll.getScrollY()));
        a.body.addView(detailsScroll, new LinearLayout.LayoutParams(-1, -1));
        a.scroll = detailsScroll;

        final LinearLayout page = a.vertical();
        page.setClipChildren(false);
        page.setClipToPadding(false);
        detailsScroll.addView(page, new ScrollView.LayoutParams(-1, -2));

        // 1. Floating Liquid Glass Top Navigation Bar (Back on left, Favorite on right;
        //    line switching is solely in the bottom inline shelf to avoid duplicate entry points)
        LinearLayout topBar = a.row();
        topBar.setClipChildren(false);
        topBar.setClipToPadding(false);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(a.dp(38), a.dp(20), a.dp(38), a.dp(8));

        Button backButton = glassNavButton(a, "‹ 返回", "detail-back", false, a::onBackPressed);
        backButton.setId(View.generateViewId());
        topBar.addView(backButton, new LinearLayout.LayoutParams(-2, a.dp(38)));

        View topSpacer = new View(a);
        topBar.addView(topSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        final boolean initialFav =
                Favorites.contains(a.prefs.getString(Prefs.FAVORITES, "[]"), s.key, listing.id);
        final Button favorite =
                glassNavButton(
                        a,
                        initialFav ? "♥ 已收藏" : "♡ 加入收藏",
                        "detail-favorite",
                        initialFav,
                        () -> {});
        favorite.setId(View.generateViewId());
        backButton.setNextFocusRightId(favorite.getId());
        favorite.setNextFocusLeftId(backButton.getId());
        topBar.addView(favorite, new LinearLayout.LayoutParams(-2, a.dp(38)));
        page.addView(topBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. Upper Hero Artwork Breathing Window (lets the HD horizontal poster shine unobstructed
        // while keeping the first row of episodes visible at the bottom of the 16:9 TV screen)
        float screenHeightDp = a.windowHeight() / a.getResources().getDisplayMetrics().density;
        int posterShowcaseDp = Math.max(76, Math.min(122, Math.round(screenHeightDp * 0.15f)));
        a.gap(page, posterShowcaseDp);

        // 3. Centered Mobile-Portrait-Style Hero Stage over the Frosted Glass Overlap Zone
        final LinearLayout hero = a.vertical();
        hero.setTag("detail-hero");
        hero.setGravity(Gravity.CENTER_HORIZONTAL);
        hero.setClipChildren(false);
        hero.setClipToPadding(false);
        hero.setPadding(a.dp(48), a.dp(2), a.dp(48), a.dp(8));
        page.addView(hero, new LinearLayout.LayoutParams(-1, -2));

        final TextView title = a.text(listing.title, 28, MainActivity.WHITE);
        title.setTag("detail-title");
        title.setTypeface(null, Typeface.BOLD);
        title.setGravity(Gravity.CENTER);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(a.dp(12), 0, a.dp(3), 0xcc000000);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(-2, -2);
        titleLp.gravity = Gravity.CENTER_HORIZONTAL;
        hero.addView(title, titleLp);

        // 4. Full-Width Bottom Details & Episode Container
        final LinearLayout info = a.vertical();
        info.setTag("detail-info-container");
        info.setClipChildren(false);
        info.setClipToPadding(false);
        info.setPadding(a.dp(38), a.dp(4), a.dp(38), a.dp(42));
        page.addView(info, new LinearLayout.LayoutParams(-1, -2));

        final TextView state = a.text("正在读取详情与剧集…", 14, MainActivity.MUTED);
        state.setTag("detail-loading");
        state.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams stateLp = new LinearLayout.LayoutParams(-2, -2);
        stateLp.gravity = Gravity.CENTER_HORIZONTAL;
        stateLp.topMargin = a.dp(14);
        hero.addView(state, stateLp);

        // Wire favorite toggle right away so it works even before detail finishes loading
        bindFavoriteAction(a, s, listing, favorite);

        MainActivity.Done<Cms.Video> present =
                v -> {
                    if ((v.id == null || v.id.trim().isEmpty()) && listing.id != null) {
                        v.id = listing.id.trim();
                    }
                    if (v.poster == null || v.poster.isEmpty()) v.poster = listing.poster;
                    if (v.title == null || v.title.isEmpty()) v.title = listing.title;
                    if (info.getChildCount() > 0 && a.current != null) {
                        View curFocus = a.getCurrentFocus();
                        if (curFocus != null && curFocus.getTag() instanceof String) {
                            a.current.focus = (String) curFocus.getTag();
                        }
                    }
                    title.setText(v.title);
                    while (hero.getChildCount() > 1) hero.removeViewAt(1);
                    info.removeAllViews();
                    bindFavoriteAction(a, s, v, favorite);

                    // 3a. Centered Glass Metadata Pills Row (Year · Area · Genres · Episode Remark)
                    LinearLayout metaRow = a.row();
                    metaRow.setGravity(Gravity.CENTER);
                    List<String> pills = collectMetaPills(v);
                    for (int i = 0; i < pills.size(); i++) {
                        TextView pill = makeGlassMetaPill(a, pills.get(i));
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

                    // 3b. Centered Rating & Cast Summary Row (TMDB + Score + Douban + Cast)
                    LinearLayout ratingRow = buildRatingAndCastRow(a, s, v);
                    LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-2, -2);
                    ratingLp.gravity = Gravity.CENTER_HORIZONTAL;
                    ratingLp.topMargin = a.dp(6);
                    hero.addView(ratingRow, ratingLp);

                    // 3c. Centered Synopsis + Expand Dialog Button
                    if (!v.description.isEmpty()) {
                        LinearLayout synopsisRow = a.vertical();
                        synopsisRow.setGravity(Gravity.CENTER_HORIZONTAL);
                        TextView synopsis = a.text(v.description, 14, 0xdcebebf5);
                        synopsis.setGravity(Gravity.CENTER);
                        synopsis.setLineSpacing(a.dp(2), 1.04f);
                        synopsis.setMaxLines(2);
                        synopsis.setEllipsize(TextUtils.TruncateAt.END);
                        synopsis.setMaxWidth(a.dp(760));
                        synopsis.setShadowLayer(a.dp(6), 0, a.dp(1), 0x88000000);
                        synopsisRow.addView(synopsis, new LinearLayout.LayoutParams(-2, -2));

                        Button moreBtn =
                                glassNavButton(
                                        a,
                                        "展开完整简介与演职员 ›",
                                        "synopsis",
                                        false,
                                        () ->
                                                new AppDialog.Builder(a)
                                                        .setTitle(v.title)
                                                        .setMessage(buildFullSynopsisMessage(v))
                                                        .setPositiveButton("关闭", null)
                                                        .show());
                        moreBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
                        moreBtn.setMinHeight(a.dp(26));
                        moreBtn.setMinimumHeight(a.dp(26));
                        moreBtn.setPadding(a.dp(12), a.dp(3), a.dp(12), a.dp(3));
                        LinearLayout.LayoutParams moreLp =
                                new LinearLayout.LayoutParams(-2, a.dp(26));
                        moreLp.topMargin = a.dp(4);
                        synopsisRow.addView(moreBtn, moreLp);

                        LinearLayout.LayoutParams synLp = new LinearLayout.LayoutParams(-2, -2);
                        synLp.gravity = Gravity.CENTER_HORIZONTAL;
                        synLp.topMargin = a.dp(6);
                        hero.addView(synopsisRow, synLp);
                    }

                    for (java.util.Iterator<Cms.Line> it = v.lines.iterator(); it.hasNext(); ) {
                        if (it.next().episodes.isEmpty()) it.remove();
                    }
                    if (v.lines.isEmpty()) {
                        TextView empty = a.text("这部影片没有返回可识别的播放线路。", 15, MainActivity.MUTED);
                        empty.setGravity(Gravity.CENTER);
                        LinearLayout.LayoutParams emptyLp = new LinearLayout.LayoutParams(-2, -2);
                        emptyLp.gravity = Gravity.CENTER_HORIZONTAL;
                        emptyLp.topMargin = a.dp(16);
                        hero.addView(empty, emptyLp);
                        favorite.requestFocus();
                        cover.load(v.poster, v.title, v.year, v.actor, v.director, true);
                        return;
                    }

                    WatchHistory.Entry bookmark = null;
                    for (WatchHistory.Entry entry : a.watchHistory())
                        if (entry.site.equals(s.key) && entry.id.equals(v.id)) {
                            bookmark = entry;
                            break;
                        }
                    final WatchHistory.Entry remembered = bookmark;

                    // 3d. Centered Prominent Play / Continue Stadium Button (Mobile Hero Style)
                    String playLabel =
                            remembered == null ? "►  开始播放" : ("►  继续播放 · " + remembered.episode);
                    final Button play =
                            heroPlayButton(
                                    a,
                                    playLabel,
                                    "detail-play",
                                    () -> {
                                        if (remembered != null) a.playBookmark(s, v, remembered);
                                        else {
                                            int prefIdx = SourcePreferences.lineIndex(a, v);
                                            a.resolvePlayer(
                                                    s,
                                                    v,
                                                    v.lines.get(prefIdx),
                                                    v.lines.get(prefIdx).episodes.get(0));
                                        }
                                    });
                    LinearLayout.LayoutParams playLp = new LinearLayout.LayoutParams(-2, a.dp(46));
                    playLp.gravity = Gravity.CENTER_HORIZONTAL;
                    playLp.topMargin = a.dp(10);
                    hero.addView(play, playLp);

                    if (remembered != null) {
                        TextView last =
                                a.text("上次观看 · " + a.historyLabel(remembered), 12, 0xb8ebebf5);
                        last.setTag("detail-history");
                        last.setGravity(Gravity.CENTER);
                        LinearLayout.LayoutParams lastLp = new LinearLayout.LayoutParams(-2, -2);
                        lastLp.gravity = Gravity.CENTER_HORIZONTAL;
                        lastLp.topMargin = a.dp(6);
                        hero.addView(last, lastLp);
                    }
                    int rememberedLine = SourcePreferences.lineIndex(a, v), rememberedPage = 0;
                    if (remembered != null)
                        for (int i = 0; i < v.lines.size(); i++)
                            if (v.lines.get(i).name.equals(remembered.line)) {
                                rememberedLine = i;
                                for (int n = 0; n < v.lines.get(i).episodes.size(); n++)
                                    if (v.lines
                                            .get(i)
                                            .episodes
                                            .get(n)
                                            .name
                                            .equals(remembered.episode))
                                        rememberedPage =
                                                (a.prefs.getBoolean(
                                                                        Prefs.EPISODES_DESCENDING,
                                                                        false)
                                                                ? v.lines.get(i).episodes.size()
                                                                        - 1
                                                                        - n
                                                                : n)
                                                        / 50;
                                break;
                            }
                    if (a.current != null && a.current.selection.selected)
                        for (int i = 0; i < v.lines.size(); i++)
                            if (v.lines.get(i).name.equals(a.current.selection.line)) {
                                rememberedLine = i;
                                rememberedPage =
                                        EpisodeSelection.boundPage(
                                                a.current.selection.page,
                                                v.lines.get(i).episodes.size());
                                break;
                            }

                    // 4a. Related Seasons Shelf (Season 1, Season 2, ...)
                    LinearLayout seasonPanel = a.vertical();
                    seasonPanel.setTag("detail-seasons");
                    info.addView(seasonPanel, new LinearLayout.LayoutParams(-1, -2));
                    populateTvRelatedSeasons(a, s, v, seasonPanel);

                    // 4b. Full-Width Episode & Line Shelf
                    final LinearLayout episodePanel = a.vertical();
                    episodePanel.setTag("detail-episodes");
                    LinearLayout.LayoutParams epPanelLp = new LinearLayout.LayoutParams(-1, -2);
                    epPanelLp.topMargin = a.dp(8);
                    info.addView(episodePanel, epPanelLp);

                    renderEpisodes(a, s, v, rememberedLine, rememberedPage, episodePanel, null);

                    View saved =
                            a.current != null
                                            && a.current.focus != null
                                            && !"detail-back".equals(a.current.focus)
                                    ? a.root.findViewWithTag(a.current.focus)
                                    : null;
                    if (saved != null) {
                        saved.requestFocus();
                    } else {
                        if (a.current != null) a.current.focus = "detail-play";
                        play.requestFocus();
                    }

                    // Kick off or upgrade poster/HD backdrop AFTER episodes and focus are ready
                    cover.load(v.poster, v.title, v.year, v.actor, v.director, true);
                };
        if (ready != null) {
            try {
                present.accept(ready);
            } catch (Exception error) {
                AppLog.w("DetailScreen", "present ready detail failed", error);
                info.addView(a.text("详情数据无法显示，请返回后重试。", 15, MainActivity.MUTED));
            }
        } else if (!a.reduced && hasPlayableLines(listing)) {
            try {
                present.accept(listing);
            } catch (Exception error) {
                AppLog.w("DetailScreen", "present listing detail failed", error);
            }
            if (listing.description == null || listing.description.trim().isEmpty()) {
                a.loadDetail(s, listing.id, present);
            }
        } else {
            // Start episode/detail fetching and poster loading strictly in parallel
            a.loadDetail(s, listing.id, present);
            cover.load(
                    listing.poster,
                    listing.title,
                    listing.year,
                    listing.actor,
                    listing.director,
                    true);
        }
    }

    private static boolean hasPlayableLines(Cms.Video v) {
        if (v == null || v.lines == null || v.lines.isEmpty()) return false;
        for (Cms.Line line : v.lines) {
            if (line != null && line.episodes != null && !line.episodes.isEmpty()) return true;
        }
        return false;
    }

    static void bindFavoriteAction(MainActivity a, Cms.Site s, Cms.Video v, Button favorite) {
        boolean isFav = Favorites.contains(a.prefs.getString(Prefs.FAVORITES, "[]"), s.key, v.id);
        favorite.setText(isFav ? "♥ 已收藏" : "♡ 加入收藏");
        styleGlassButton(a, favorite, favorite.hasFocus(), isFav);
        favorite.setOnClickListener(
                view -> {
                    a.prefs
                            .edit()
                            .putString(
                                    Prefs.FAVORITES,
                                    Favorites.toggle(
                                            a.prefs.getString(Prefs.FAVORITES, "[]"), s.key, v))
                            .apply();
                    boolean nowFav =
                            Favorites.contains(
                                    a.prefs.getString(Prefs.FAVORITES, "[]"), s.key, v.id);
                    favorite.setText(nowFav ? "♥ 已收藏" : "♡ 加入收藏");
                    styleGlassButton(a, favorite, favorite.hasFocus(), nowFav);
                });
        favorite.setOnFocusChangeListener(
                (view, focus) -> {
                    boolean nowFav =
                            Favorites.contains(
                                    a.prefs.getString(Prefs.FAVORITES, "[]"), s.key, v.id);
                    styleGlassButton(a, favorite, focus, nowFav);
                });
    }

    static Button glassNavButton(
            MainActivity a, String label, String tag, final boolean activeAccent, Runnable action) {
        final Button b = a.button(label, tag, action);
        b.setSingleLine(true);
        b.setEllipsize(TextUtils.TruncateAt.END);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        b.setMinHeight(a.dp(36));
        b.setMinimumHeight(a.dp(36));
        b.setPadding(a.dp(16), a.dp(6), a.dp(16), a.dp(6));
        b.setClipToOutline(false);
        b.setOutlineProvider(null);
        styleGlassButton(a, b, false, activeAccent);
        b.setOnFocusChangeListener((view, focus) -> styleGlassButton(a, b, focus, activeAccent));
        b.addOnLayoutChangeListener(
                (v, l, t, r, bot, ol, ot, or, ob) -> {
                    int h = bot - t;
                    if (h > 0 && b.getBackground() instanceof GradientDrawable) {
                        ((GradientDrawable) b.getBackground()).setCornerRadius(h / 2f);
                    }
                });
        return b;
    }

    static void styleGlassButton(MainActivity a, Button b, boolean focused, boolean activeAccent) {
        FocusMotion.unclipAncestors(b);
        int pl = b.getPaddingLeft() > 0 ? b.getPaddingLeft() : a.dp(16);
        int pt = b.getPaddingTop() > 0 ? b.getPaddingTop() : a.dp(6);
        int pr = b.getPaddingRight() > 0 ? b.getPaddingRight() : a.dp(16);
        int pb = b.getPaddingBottom() > 0 ? b.getPaddingBottom() : a.dp(6);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        int h = b.getHeight() > 0 ? b.getHeight() : b.getMinimumHeight();
        d.setCornerRadius(h > 0 ? h / 2f : a.dp(19));
        if (focused) {
            d.setColor(MainActivity.WHITE);
            b.setTextColor(MainActivity.DARK);
            b.animate().scaleX(1.04f).scaleY(1.04f).setDuration(130).start();
        } else {
            d.setColor(activeAccent ? 0xcc3a4e68 : 0x781c202c);
            d.setStroke(Math.max(1, a.dp(1)), activeAccent ? 0x8082b4ff : 0x38ffffff);
            b.setTextColor(MainActivity.WHITE);
            b.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
        }
        b.setBackground(d);
        b.setPadding(pl, pt, pr, pb);
    }

    static Button heroPlayButton(MainActivity a, String label, String tag, Runnable action) {
        final Button b = a.button(label, tag, action);
        b.setSingleLine(true);
        b.setEllipsize(TextUtils.TruncateAt.END);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        b.setTypeface(null, Typeface.BOLD);
        b.setMinWidth(a.dp(240));
        b.setMinimumWidth(a.dp(240));
        b.setMinHeight(a.dp(46));
        b.setMinimumHeight(a.dp(46));
        b.setPadding(a.dp(32), a.dp(9), a.dp(32), a.dp(9));
        b.setClipToOutline(false);
        b.setOutlineProvider(null);
        styleHeroPlayButton(a, b, false);
        b.setOnFocusChangeListener((v, focus) -> styleHeroPlayButton(a, b, focus));
        b.addOnLayoutChangeListener(
                (v, l, t, r, bot, ol, ot, or, ob) -> {
                    int h = bot - t;
                    if (h > 0 && b.getBackground() instanceof GradientDrawable) {
                        ((GradientDrawable) b.getBackground()).setCornerRadius(h / 2f);
                    }
                });
        return b;
    }

    static void styleHeroPlayButton(MainActivity a, Button b, boolean focused) {
        FocusMotion.unclipAncestors(b);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        int h = b.getHeight() > 0 ? b.getHeight() : b.getMinimumHeight();
        d.setCornerRadius(h > 0 ? h / 2f : a.dp(23));
        if (focused) {
            d.setColor(MainActivity.WHITE);
            b.setTextColor(0xff090c14);
            b.animate().scaleX(1.05f).scaleY(1.05f).setDuration(140).start();
        } else {
            d.setColor(0xd8ffffff);
            d.setStroke(Math.max(1, a.dp(1)), 0x66ffffff);
            b.setTextColor(0xff0c101a);
            b.animate().scaleX(1f).scaleY(1f).setDuration(140).start();
        }
        b.setBackground(d);
        b.setPadding(a.dp(32), a.dp(9), a.dp(32), a.dp(9));
    }

    static List<String> collectMetaPills(Cms.Video v) {
        List<String> pills = new ArrayList<>();
        if (v.year != null && !v.year.trim().isEmpty()) pills.add(v.year.trim());
        if (v.area != null && !v.area.trim().isEmpty()) pills.add(v.area.trim());
        if (v.tag != null && !v.tag.trim().isEmpty()) {
            String[] parts = v.tag.split("[/,，、\\s]+");
            int added = 0;
            for (String p : parts) {
                String clean = p.trim();
                if (!clean.isEmpty() && !pills.contains(clean)) {
                    pills.add(clean);
                    if (++added >= 3) break;
                }
            }
        }
        if (v.remarks != null && !v.remarks.trim().isEmpty()) {
            pills.add(v.remarks.trim());
        } else if (!v.lines.isEmpty() && !v.lines.get(0).episodes.isEmpty()) {
            pills.add("共 " + v.lines.get(0).episodes.size() + " 集");
        }
        return pills;
    }

    static TextView makeGlassMetaPill(MainActivity a, String text) {
        TextView tv = a.text(text, 12, 0xf0ffffff);
        tv.setSingleLine(true);
        tv.setPadding(a.dp(11), a.dp(4), a.dp(11), a.dp(4));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(a.dp(8));
        bg.setColor(0x52181c26);
        bg.setStroke(Math.max(1, a.dp(1)), 0x33ffffff);
        tv.setBackground(bg);
        return tv;
    }

    static LinearLayout buildRatingAndCastRow(MainActivity a, Cms.Site s, Cms.Video v) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);

        final TextView doubanBadge = a.text("", 12, 0xff6ee7b7);
        doubanBadge.setTag("detail-douban-rating");
        doubanBadge.setTypeface(null, Typeface.BOLD);
        doubanBadge.setPadding(a.dp(10), a.dp(3.5f), a.dp(10), a.dp(3.5f));
        doubanBadge.setBackground(MobileDetailScreen.glassBg(a, 0x3800b51d, 0x6634d399, 999));
        LinearLayout.LayoutParams dbLp = new LinearLayout.LayoutParams(-2, -2);
        dbLp.rightMargin = a.dp(8);
        row.addView(doubanBadge, dbLp);

        final TextView rtBadge = a.text("", 12, 0xffffb4a2);
        rtBadge.setTag("detail-rt-rating");
        rtBadge.setTypeface(null, Typeface.BOLD);
        rtBadge.setPadding(a.dp(10), a.dp(3.5f), a.dp(10), a.dp(3.5f));
        rtBadge.setBackground(MobileDetailScreen.glassBg(a, 0x38fa320a, 0x66ff6b4a, 999));
        LinearLayout.LayoutParams rtLp = new LinearLayout.LayoutParams(-2, -2);
        rtLp.rightMargin = a.dp(8);
        row.addView(rtBadge, rtLp);

        MobileDetailScreen.updateRatingBadges(doubanBadge, rtBadge, v, 0.0);
        ImmersivePoster.resolveDoubanRating(
                a,
                v.title,
                v.year,
                score -> MobileDetailScreen.updateRatingBadges(doubanBadge, rtBadge, v, score));

        if (s != null && s.name != null && !s.name.isEmpty()) {
            TextView siteLabel = a.text(s.name, 12, 0xe6ffffff);
            siteLabel.setPadding(a.dp(10), a.dp(3.5f), a.dp(10), a.dp(3.5f));
            siteLabel.setBackground(MobileDetailScreen.glassBg(a, 0x26ffffff, 0x38ffffff, 999));
            row.addView(siteLabel);
        }

        if (v.actor != null && !v.actor.trim().isEmpty()) {
            String cast = v.actor.trim().replaceAll("\\s+", " / ");
            if (cast.length() > 28) cast = cast.substring(0, 28) + "…";
            TextView actorTv = a.text("   主演: " + cast, 13, 0xc8d8d8e2);
            actorTv.setSingleLine(true);
            actorTv.setEllipsize(TextUtils.TruncateAt.END);
            row.addView(actorTv);
        }
        return row;
    }

    static String extractScore(String remarks) {
        if (remarks != null) {
            Matcher m = SCORE_PATTERN.matcher(remarks);
            if (m.find()) return m.group(1);
        }
        return "8.6";
    }

    static String buildFullSynopsisMessage(Cms.Video v) {
        StringBuilder sb = new StringBuilder();
        if (v.director != null && !v.director.trim().isEmpty()) {
            sb.append("导演：").append(v.director.trim()).append("\n");
        }
        if (v.actor != null && !v.actor.trim().isEmpty()) {
            sb.append("主演：").append(v.actor.trim()).append("\n");
        }
        if (sb.length() > 0) sb.append("\n");
        sb.append(v.description == null ? "" : v.description.trim());
        return sb.toString();
    }

    static void renderEpisodes(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            int lineIndex,
            int page,
            LinearLayout panel,
            String focusTag) {
        if (a.current != null)
            a.current.selection.select(
                    video.lines.get(lineIndex).name,
                    page,
                    video.lines.get(lineIndex).episodes.size());
        panel.removeAllViews();
        Cms.Line line = video.lines.get(lineIndex);
        final boolean descending = a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false);

        // 1. Inline Playback Line Switcher Section
        LinearLayout lineHeader = a.row();
        lineHeader.setGravity(Gravity.CENTER_VERTICAL);
        lineHeader.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(6));
        TextView lineTitle = a.text("播放线路", 16, MainActivity.WHITE);
        lineTitle.setTypeface(null, Typeface.BOLD);
        lineHeader.addView(lineTitle);
        TextView lineSub = a.text("  " + video.lines.size() + " 条可用线路", 12, MainActivity.MUTED);
        lineHeader.addView(lineSub, new LinearLayout.LayoutParams(0, -2, 1f));
        Button prefLineBtn =
                a.navButton(
                        "默认播放线路", "line-preferred", () -> SourcePreferences.chooseLine(a, video));
        lineHeader.addView(prefLineBtn);
        panel.addView(lineHeader, new LinearLayout.LayoutParams(-1, -2));

        CategoryFlow sources = new CategoryFlow(a, () -> {});
        sources.setTag("detail-line-buttons");
        sources.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(12));
        panel.addView(sources, new LinearLayout.LayoutParams(-1, -2));
        for (int n = 0; n < video.lines.size(); n++) {
            final int index = n;
            final boolean selected = n == lineIndex;
            final Button choice =
                    a.button(
                            video.lines.get(n).name,
                            "detail-line:" + n,
                            () -> {
                                renderEpisodes(a, site, video, index, 0, panel, null);
                                View play = a.root.findViewWithTag("detail-play");
                                if (play instanceof Button) {
                                    ((Button) play).setText("►  开始播放");
                                    play.setOnClickListener(
                                            v -> {
                                                a.resumeAt = 0;
                                                a.resolvePlayer(
                                                        site,
                                                        video,
                                                        video.lines.get(index),
                                                        video.lines.get(index).episodes.get(0));
                                            });
                                }
                                View next = panel.findViewWithTag("detail-line:" + index);
                                if (next != null) next.requestFocus();
                            });
            choice.setSelected(selected);
            choice.setSingleLine(true);
            choice.setEllipsize(TextUtils.TruncateAt.END);
            choice.setMinWidth(0);
            choice.setMinimumWidth(0);
            choice.setTextSize(13);
            choice.setMinHeight(a.dp(36));
            choice.setMinimumHeight(a.dp(36));
            choice.setBackground(a.bg(selected ? 0xff3b5472 : 0x991c202b, 18));
            choice.setPadding(a.dp(15), a.dp(7), a.dp(15), a.dp(7));
            choice.setOnKeyListener(
                    (v, keyCode, event) -> {
                        FocusMotion.key(a, v, keyCode, event);
                        if (event.getAction() == android.view.KeyEvent.ACTION_DOWN
                                && (keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                        || keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT)) {
                            lastLineHorizontalDpadTime = android.os.SystemClock.uptimeMillis();
                        }
                        return false;
                    });
            choice.setOnFocusChangeListener(
                    (view, focus) -> {
                        FocusMotion.style(
                                a,
                                choice,
                                focus,
                                selected ? 0xff3b5472 : 0x991c202b,
                                MainActivity.WHITE,
                                18,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.03f);
                        choice.setPadding(a.dp(15), a.dp(7), a.dp(15), a.dp(7));
                        if (focus
                                && a.isTvDevice()
                                && !selected
                                && android.os.SystemClock.uptimeMillis()
                                                - lastLineHorizontalDpadTime
                                        < 350L) {
                            choice.postDelayed(
                                    () -> {
                                        if (choice.hasFocus()
                                                && UiCompat.isAttached(choice)
                                                && !selected) {
                                            choice.performClick();
                                        }
                                    },
                                    120);
                        }
                    });
            sources.addView(choice);
        }

        // 2. Episode Section Header + Sort + Pagination Controls
        LinearLayout orderRow = a.row();
        orderRow.setGravity(Gravity.CENTER_VERTICAL);
        orderRow.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView epHeader = a.text("选集列表", 17, MainActivity.WHITE);
        epHeader.setTypeface(null, Typeface.BOLD);
        orderRow.addView(epHeader);

        TextView count =
                a.text("   共 " + line.episodes.size() + " 集 · 完整剧集名称直显", 13, MainActivity.MUTED);
        orderRow.addView(count, new LinearLayout.LayoutParams(0, -2, 1));

        Button order =
                a.navButton(
                        descending ? "↓ 倒序" : "↑ 正序",
                        "episodes-order",
                        () -> {
                            boolean next = !descending;
                            a.prefs.edit().putBoolean(Prefs.EPISODES_DESCENDING, next).apply();
                            renderEpisodes(a, site, video, lineIndex, 0, panel, "episodes-order");
                        });
        order.setSelected(descending);
        order.setContentDescription("选集排序：" + (descending ? "倒序，点击改为正序" : "正序，点击改为倒序"));
        orderRow.addView(order);
        panel.addView(orderRow, new LinearLayout.LayoutParams(-1, -2));

        int start = page * 50, end = Math.min(start + 50, line.episodes.size());

        // Range pills bar when there are > 50 episodes
        if (line.episodes.size() > 50) {
            LinearLayout pages = a.row();
            pages.setGravity(Gravity.CENTER_VERTICAL);
            pages.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(10));
            if (page > 0)
                a.addButton(
                        pages,
                        a.navButton(
                                "上一组",
                                "episodes-previous",
                                () ->
                                        renderEpisodes(
                                                a, site, video, lineIndex, page - 1, panel, null)));
            if (end < line.episodes.size())
                a.addButton(
                        pages,
                        a.navButton(
                                "下一组",
                                "episodes-next",
                                () -> {
                                    renderEpisodes(
                                            a, site, video, lineIndex, page + 1, panel, null);
                                    View first =
                                            panel.findViewWithTag(
                                                    "episode:"
                                                            + line.name
                                                            + ":"
                                                            + (descending
                                                                    ? line.episodes.size() - 1 - end
                                                                    : end));
                                    if (first != null) first.requestFocus();
                                }));
            a.addButton(
                    pages,
                    a.navButton(
                            "全部选集 (" + line.episodes.size() + ")",
                            "episodes-all",
                            () -> {
                                String[] labels = new String[line.episodes.size()];
                                for (int n = 0; n < labels.length; n++)
                                    labels[n] =
                                            line.episodes.get(
                                                            descending
                                                                    ? line.episodes.size() - 1 - n
                                                                    : n)
                                                    .name;
                                new AppDialog.Builder(a)
                                        .setTitle(line.name)
                                        .setItems(
                                                labels,
                                                (dialog, n) ->
                                                        a.resolvePlayer(
                                                                site,
                                                                video,
                                                                line,
                                                                line.episodes.get(
                                                                        descending
                                                                                ? line.episodes
                                                                                                .size()
                                                                                        - 1
                                                                                        - n
                                                                                : n)))
                                        .setNegativeButton("取消", null)
                                        .show();
                            }));
            TextView rangeHint =
                    a.text("  当前显示第 " + (start + 1) + " - " + end + " 项", 12, MainActivity.MUTED);
            pages.addView(rangeHint);
            panel.addView(pages, new LinearLayout.LayoutParams(-1, -2));
        }

        // 3. Full-Title Multi-Line Episode Grid (No separate focused-title bar needed!)
        final int columns = computeColumnsPerRow(line, start, end, descending);
        Object batchToken = new Object();
        panel.setTag(batchToken);
        LinearLayout cells = a.vertical();
        cells.setClipChildren(false);
        cells.setClipToPadding(false);
        panel.addView(cells, new LinearLayout.LayoutParams(-1, -2));
        appendEpisodeCells(
                a,
                site,
                video,
                line,
                start,
                end,
                columns,
                cells,
                panel,
                batchToken,
                a.generation,
                descending,
                focusTag);
        if ("episodes-order".equals(focusTag)) order.requestFocus();
    }

    /**
     * Chooses the optimal number of columns per row on TV so every episode's full name fits
     * comfortably without truncation.
     */
    private static int computeColumnsPerRow(Cms.Line line, int start, int end, boolean descending) {
        int maxLen = 0;
        for (int i = start; i < end; i++) {
            int idx = descending ? line.episodes.size() - 1 - i : i;
            String name = line.episodes.get(idx).name;
            if (name != null && name.length() > maxLen) {
                maxLen = name.length();
            }
        }
        if (maxLen >= 24) return 3;
        if (maxLen >= 13) return 4;
        return 5;
    }

    static void appendEpisodeCells(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            int start,
            int end,
            int columns,
            LinearLayout cells,
            LinearLayout panel,
            Object token,
            int ticket,
            boolean descending,
            String focusTag) {
        if (ticket != a.generation || panel.getTag() != token) return;
        int batchSize = columns * 4;
        int stop = Math.min(end, start + batchSize);
        LinearLayout row = null;
        final List<LinearLayout> createdRows = new ArrayList<>();
        for (int i = start; i < stop; i++) {
            if ((i - start) % columns == 0) {
                row = a.row();
                row.setGravity(Gravity.TOP);
                row.setClipChildren(false);
                row.setClipToPadding(false);
                cells.addView(row, new LinearLayout.LayoutParams(-1, -2));
                createdRows.add(row);
            }
            final int originalIndex = descending ? line.episodes.size() - 1 - i : i;
            final Cms.Episode episode = line.episodes.get(originalIndex);
            final Button button =
                    a.button(
                            episode.name,
                            "episode:" + line.name + ":" + originalIndex,
                            () -> {
                                a.resumeAt = 0;
                                a.resolvePlayer(site, video, line, episode);
                            });
            button.setContentDescription(episode.name);
            // Display the COMPLETE episode name directly inside the button (multi-line, no
            // ellipsis)
            button.setSingleLine(false);
            button.setMaxLines(6);
            button.setEllipsize(null);
            button.setIncludeFontPadding(false);
            button.setTextSize(TypedValue.COMPLEX_UNIT_SP, columns <= 3 ? 13.5f : 14f);
            button.setLineSpacing(a.dp(2), 1.06f);
            button.setGravity(
                    episode.name != null && episode.name.length() > 12
                            ? (Gravity.START | Gravity.CENTER_VERTICAL)
                            : Gravity.CENTER);
            button.setMinHeight(a.dp(54));
            button.setMinimumHeight(a.dp(54));
            button.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            button.setBackground(a.bg(0xb81b202c, 12));
            button.setOnFocusChangeListener(
                    (view, focus) -> {
                        FocusMotion.style(
                                a,
                                button,
                                focus,
                                0xb81b202c,
                                MainActivity.WHITE,
                                12,
                                MainActivity.WHITE,
                                MainActivity.DARK,
                                false,
                                1.022f);
                        if (focus && a.current != null) {
                            a.current.episodeFocus = originalIndex;
                            a.current.episodeFocusLine = line.name;
                        }
                    });
            LinearLayout.LayoutParams cell =
                    new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            cell.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(6));
            row.addView(button, cell);
            if (focusTag != null && focusTag.equals(button.getTag())) button.requestFocus();
        }
        if (row != null) {
            int rem = (stop - start) % columns;
            if (rem > 0) {
                for (int n = rem; n < columns; n++) {
                    View spacer = new View(a);
                    LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(0, 1, 1f);
                    sp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(6));
                    row.addView(spacer, sp);
                }
            }
        }
        // Equalize button heights within each row so multi-line titles align cleanly
        for (final LinearLayout createdRow : createdRows) {
            createdRow.post(
                    () -> {
                        int maxH = a.dp(54);
                        for (int c = 0; c < createdRow.getChildCount(); c++) {
                            View ch = createdRow.getChildAt(c);
                            if (ch instanceof Button && ch.getHeight() > maxH) {
                                maxH = ch.getHeight();
                            }
                        }
                        for (int c = 0; c < createdRow.getChildCount(); c++) {
                            View ch = createdRow.getChildAt(c);
                            if (ch instanceof Button && ch.getHeight() < maxH) {
                                ((Button) ch).setMinHeight(maxH);
                                ((Button) ch).setMinimumHeight(maxH);
                            }
                        }
                    });
        }
        if (stop < end)
            cells.postOnAnimation(
                    () ->
                            appendEpisodeCells(
                                    a,
                                    site,
                                    video,
                                    line,
                                    stop,
                                    end,
                                    columns,
                                    cells,
                                    panel,
                                    token,
                                    ticket,
                                    descending,
                                    focusTag));
        else if (a.current != null
                && a.current.focus != null
                && a.current.focus.startsWith("episode:")) {
            View focus = a.getCurrentFocus();
            Object tag = focus == null ? null : focus.getTag();
            if (focus == null || "detail-play".equals(tag) || "detail-back".equals(tag)) {
                View saved = panel.findViewWithTag(a.current.focus);
                if (saved != null) saved.requestFocus();
            }
        }
    }

    static void populateTvRelatedSeasons(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video currentVideo,
            final LinearLayout seasonPanel) {
        final MobileDetailScreen.SeasonMeta curMeta =
                MobileDetailScreen.parseSeasonMeta(currentVideo.title);
        if (!curMeta.explicit) return;
        final String baseKey =
                curMeta.baseTitle == null
                        ? ""
                        : curMeta.baseTitle
                                .toLowerCase()
                                .replaceAll("[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。]", "")
                                .trim();
        if (baseKey.isEmpty()) return;
        final int ticket = a.generation;
        seasonPanel.postDelayed(
                () -> {
                    if (a.isFinishing() || a.isDestroyed() || ticket != a.generation) return;
                    a.submitPage(
                            () -> {
                                try {
                                    List<Cms.Video> found =
                                            Cms.listing(
                                                            SourceController.engine(a, site)
                                                                    .search(curMeta.baseTitle, 1))
                                                    .videos;
                                    if (found == null || found.isEmpty()) return;
                                    final Map<Integer, Cms.Video> bySeason = new TreeMap<>();
                                    final Map<Integer, String> labels = new TreeMap<>();
                                    bySeason.put(curMeta.seasonNumber, currentVideo);
                                    labels.put(curMeta.seasonNumber, curMeta.seasonLabel);
                                    for (Cms.Video cand : found) {
                                        if (cand == null || cand.title == null) continue;
                                        MobileDetailScreen.SeasonMeta candMeta =
                                                MobileDetailScreen.parseSeasonMeta(cand.title);
                                        String candKey =
                                                candMeta.baseTitle
                                                        .toLowerCase()
                                                        .replaceAll(
                                                                "[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。]",
                                                                "")
                                                        .trim();
                                        if (!baseKey.equals(candKey)) continue;
                                        if (!curMeta.explicit
                                                && !candMeta.explicit
                                                && !Objects.equals(cand.id, currentVideo.id)) {
                                            continue;
                                        }
                                        if (!bySeason.containsKey(candMeta.seasonNumber)) {
                                            bySeason.put(candMeta.seasonNumber, cand);
                                            labels.put(candMeta.seasonNumber, candMeta.seasonLabel);
                                        }
                                    }
                                    if (bySeason.size() < 2) return;
                                    final List<Integer> seasonNums =
                                            new ArrayList<>(bySeason.keySet());
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || a.isDestroyed()
                                                        || ticket != a.generation) return;
                                                seasonPanel.removeAllViews();
                                                a.gap(seasonPanel, 10);
                                                CategoryFlow flow = new CategoryFlow(a, () -> {});
                                                flow.setTag("detail-season-buttons");
                                                flow.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
                                                seasonPanel.addView(
                                                        flow,
                                                        new LinearLayout.LayoutParams(-1, -2));
                                                for (final Integer sNum : seasonNums) {
                                                    final Cms.Video targetVid = bySeason.get(sNum);
                                                    String sLabel = labels.get(sNum);
                                                    boolean active =
                                                            Objects.equals(
                                                                            targetVid.id,
                                                                            currentVideo.id)
                                                                    || sNum == curMeta.seasonNumber;
                                                    Button btn =
                                                            a.button(
                                                                    sLabel,
                                                                    "detail-season:" + sNum,
                                                                    () -> {
                                                                        if (!Objects.equals(
                                                                                targetVid.id,
                                                                                currentVideo.id)) {
                                                                            show(
                                                                                    a, site,
                                                                                    targetVid,
                                                                                    null);
                                                                        }
                                                                    });
                                                    btn.setSingleLine(true);
                                                    btn.setMinWidth(0);
                                                    btn.setMinimumWidth(0);
                                                    btn.setMinHeight(a.dp(36));
                                                    btn.setMinimumHeight(a.dp(36));
                                                    btn.setPadding(
                                                            a.dp(14), a.dp(6), a.dp(14), a.dp(6));
                                                    if (active) {
                                                        btn.setBackground(a.bg(0xff465c76, 10));
                                                        btn.setPadding(
                                                                a.dp(14), a.dp(6), a.dp(14),
                                                                a.dp(6));
                                                        btn.setOnFocusChangeListener(
                                                                (v, f) -> {
                                                                    FocusMotion.style(
                                                                            a,
                                                                            btn,
                                                                            f,
                                                                            0xff465c76,
                                                                            MainActivity.WHITE,
                                                                            10,
                                                                            MainActivity.WHITE,
                                                                            MainActivity.DARK,
                                                                            true,
                                                                            1.02f);
                                                                    btn.setPadding(
                                                                            a.dp(14), a.dp(6),
                                                                            a.dp(14), a.dp(6));
                                                                });
                                                    }
                                                    flow.addView(btn);
                                                }
                                            });
                                } catch (Exception ignored) {
                                }
                            });
                },
                450);
    }
}
