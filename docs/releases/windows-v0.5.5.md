# Windows 0.5.5 (`windows-v0.5.5`)

- **Platform:** Windows x64 (`windows-v0.5.5`)
- **Version:** `0.5.5` (build `55`)
- **Release Date:** 2026-11-09

## Additions & Fixes

- **Universal TVBox / 影视仓 `csp_*` & 4K / 四盘 Site Adaptation (`玩偶哥哥`、`聚剧┃四盘`、`王二小放牛娃` 全量线路可用):**
  - Restored and adapted `👽玩偶哥哥┃4K弹幕` (`csp_WoGGGuard` / `csp_AiNewWoggGuard`), `💡聚剧┃四盘` (`csp_SeedhubGuard`), `🎈盘搜┃四盘` (`csp_S_zpsGuard`), `🦋易搜┃四盘` (`csp_S_zpsGuard`), `🐌盘她┃夸父` (`csp_YpanSoGuard`), `🐞盘他┃嘟嘟` (`csp_BpanSoGuard`), `🌶️抠抠┃搜搜` (`csp_KkSsGuard`), `🌈优汐┃搜搜` (`csp_UuSsGuard`), and `🧲新6V┃磁力` (`csp_SixVGuard`) so they appear in `切换片源` as available (`可用`) and pull full VOD catalogs, categories, search, and direct playable lines.
  - Expanded `CspBridge` to cover `csp_AiNew*` (`花卷┃4K`, `观影┃4K`, `七味┃4K`, `盘库┃4K`, `虎斑┃4K`, `木偶┃4K`, `多多┃4K`, `快影┃4K`, `蜡笔┃4K`, `闪电┃4K`, `剧透┃4K`, `立播┃4K`, `原盘┃4K`, `蜗牛┃4K`, `盘迷┃4K`, `逸动┃4K`), `csp_Wex*` (`韩剧/瓜子/独播/闪电/文才/小枫/贱片/下饭/师兄/粉猪/咸鱼/追剧/柚子/柠檬/太奇/零七/柿子/黄人/伊影/热播/伯伯/爱看┃秒播`), `csp_ManJuAi*` / `csp_DuanJuAi*` (`漫短/漫剧/短剧`), `csp_Anime*` (`共和/稀饭/次元/魔都┃动漫`), `csp_Book*` (`小红/小马/悦庭/爱上┃听书`), `csp_Children*` (`宝宝/贝贝/兔兔┃儿歌`), `csp_Music*` (`跳舞┃教学`, `戏曲┃秒播`, `蜻蜓┃电台`, `KTV/小酷/易听/酷听/轮回┃音乐`), `csp_Sport*` (`飞球/瓜子/球通/八八/咖啡/WWE┃体育`), `csp_LiveAi*` (`虎牙/斗鱼/哔哩┃直播`), and `csp_So*` (`盘搜/九七/爱盘/卡卡/全盘┃综合`).
  - Filtered non-content configuration/push placeholders (`csp_MyPanGuard`, `csp_PanConfigGuard`, `csp_MyDriveGuard`, `csp_PushGuard`, unconfigured `csp_AListGuard`/`csp_WebDAVGuard`/`csp_EmbyGuard`) out of the source picker.

## Test Scope & Remaining Limitations

- Passed `scripts/check_public_content.py`, `scripts/test_drpy_assets.py`, `flutter/test_*.py`, and all 327 Flutter unit & widget tests on Windows x64.
- Unconfigured local DIY storage mounts (`AList` / `WebDAV` / `Emby` without a server URL) remain hidden until configured.
