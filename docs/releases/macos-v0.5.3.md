# macOS 0.5.3 (`macos-v0.5.3`)

- **Platform:** macOS (`macos-v0.5.3`)
- **Version:** `0.5.3` (build `53`)
- **Release Date:** 2026-11-09

## Additions & Fixes

- **Full TVBox / 影视仓 `csp_*` VOD & Live Site Adaptation (`饭太硬` 36/36 Non-Netdisk Sites Supported):**
  - Synchronized the expanded cross-platform `CspBridge` site adapter pool (`16` verified MacCMS VOD backends) for mainstream `csp_*` sites (`厂长┃不卡`, `海绵┃不卡`, `立播┃不卡`, `瓜子┃不卡`, `糯米┃秒播`, `文采┃秒播`, `热播┃多线`, `茉莉┃多线`, `剧圈┃多线`, `荐片┃多线`, `AI剧┃弹幕`, `韩圈┃韩剧`, `漫国┃动漫`, `巴士┃动漫`, etc.).
  - Added `Bili` / audio / sports / live adapters for `🎙️易听┃音乐` (`csp_MusicGuard`), `🎧有声┃小说` (`csp_YueTingGuard`), `🎧听书┃音频` (`csp_TingShu`), `⚽八八┃看球` (`csp_KanqiuGuard`), `🏀多多┃回放` (`csp_DoubaoGuard`), `⚽吃瓜┃看球` (`csp_LiveGz`), and `📺一直播┃直播` (`csp_AllliveGuard`).
  - Added automatic `CspBridge` fallback when a `GuardSource` script fails or returns empty listings.
- **Remote `drpy2.min.js` & `assets://js/lib/` Module Support:**
  - Automatically routes remote `drpy2.min.js` rule extensions (`ext`) and `assets://js/lib/cheerio.min.js` scripts through the built-in `DrpySource` runtime with `muban` template injection.
  - Resolves `assets://js/lib/cheerio.min.js`, `assets://js/lib/crypto-js.js`, `assets://js/lib/cat.js`, and relative `assets://js/lib/*` modules inside `JsSourceHost`.
- **Source Picker (`切换片源`) & UI Refinements:**
  - Automatically hides netdisk-only (`玩偶`, `立播┃四盘`, `聚剧┃四盘`, `二小`, `木偶`, `蜡笔`, `至臻`, `闪电`, `云盘`, `盘他`, `夸克`, `UC`, `阿里`, `百度`, `123`) and placeholder (`csp_MyDrive`, `csp_SixV`, empty `csp_XPathGuard`) entries from `切换片源`, and collapses any remaining unsupported plugins into a compact expandable footer (`当前设备未适配`).
  - Upgraded the source picker (`SourceChoiceSliver`) to a responsive 2/3-column grid with search and clean Glasswork visual styling.
  - Improved cross-source playable detail matching (`playableDetail`) with normalized title matching and a 12-second per-batch timeout.

## Test Scope & Remaining Limitations

- Passed `scripts/check_public_content.py`, `scripts/test_drpy_assets.py`, `flutter/test_*.py`, and the `flutter test` suite on macOS.
- Android-only native `.jar` Spider plugins without a cross-platform `CspBridge` / `GuardSource` / `DrpySource` adapter remain unsupported on desktop.
