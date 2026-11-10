# Android 电视 / 盒子 0.5.7

- 发布平台：Android 电视 / 盒子（`android-tv`）
- 版本：`0.5.7`（`versionCode 57`）
- 发布日期：2026-11-08
- 构建提交：`d2f7c51ef08216c0eed8a6184828c4fc09a2d513`
- 安装包：`MarcoMovie-0.5.7-android-tv.apk`（兼容旧名：`MarcoMovie-0.5.7-preview.apk`）

## 本次修复与改进

1. **修复国外电影与国内动漫横版剧照/海报获取（告别竖版封面回退）**：
   - 重构 `ImmersivePoster.findVerifiedDoubanSubjects`：将已失效返回空数组的 `subject_suggest` 接口升级为稳定可用的 `m.douban.com/search` 移动端检索并保留回退通道，综合片名精确度、是否已上映（过滤无剧照占位词条）、有效海报与评分进行排序，对前 3 个高置信候选条目并发拉取 `rexxar/api/v2/movie/{id}/photos` 16:9 高清横版剧照。
   - 修复豆瓣图片 CDN 防盗链挑战：在 `ImageLoader.normalizeBackdropCdnUrl` 中将 `img4`–`img9.doubanio.com` 及 `qnmob*-sign.doubanio.com` 统一重写为稳定直连的 `img1.doubanio.com` 并规范化 `/view/photo/l/` 路径，解决国外大片剧照返回 987 字节 HTML 拦截页的问题。
   - 强化国内动漫与国漫年番横版封面检索：为哔哩哔哩番剧检索补齐 `buvid3` Cookie（消除 HTTP 412 拦截），支持从 `eps[0].cover` 提取 16:9 横版单集封面，并优化 `年番`、`第X季`、冒号前续集序号（如 `毒液3：最后一舞`）及尾部年份（如 `奥德赛2026`）的片名归一化匹配。
2. **屏蔽字幕调整页方向键调位置时底层设置页跟随滚动**：
   - 修复 `PlaybackControls.showSubtitleAdjuster` 在方向键微调字幕位置时每按一次方向键都触发 `onChanged.run()`（即 `SettingsScreen` 的 `a::refresh`）导致底层设置页面不断重绘和滚动的问题；仅在退出字幕调节弹窗时刷新一次设置页摘要。
   - 进入字幕调节弹窗时锁定底层 `ScrollView` 的焦点穿透（`FOCUS_BLOCK_DESCENDANTS`）与滚动偏移，并在“十字方向键调位置”激活期间将上下左右焦点及 `ACTION_DOWN`/`ACTION_UP` 按键事件完全闭环拦截在弹窗内。
3. **选集详情页评分升级为豆瓣评分与烂番茄指数展示**：
   - 将电视端 `DetailScreen.buildRatingAndCastRow` 原有的 `TMDB X.X 豆` 评分条升级为与手机端一致的**豆瓣评分（`豆瓣 ★ X.X`）**与**烂番茄指数（`烂番茄 XX%`）**双徽章展示，并接入 `ImmersivePoster.resolveDoubanRating` 实时回填真实豆瓣高置信评分。

## 验证范围

- 通过国外电影（《蜘蛛侠：英雄无归》《沙丘2》《盗梦空间》《死侍与金刚狼》《毒液3：最后一舞》《阿凡达：水之道》《奥德赛2026》等）与国内动漫（《仙逆》《凡人修仙传》《完美世界》《斗破苍穹年番》《吞噬星空》《遮天》《剑来》《牧神记》等）16 部样本的 16:9 横版剧照解析与 CDN 下载实测。
- 通过 `ReviewFixChecks`、`SeekGestureChecks`、`UpdateControllerChecks`、`UpdateEditionChecks`、`TvInputControllerChecks` 与 `Checks` 本地回归测试。
- 通过 `check_public_content.py` 公开内容合规扫描与 `build_android.py` 16KB 页对齐及 V1/V2/V3 正式签名校验。

## 已知限制

- 33 项待移植 Guard 插件路由及原生 Python 完整运行时仍在推进中，iPhone 正式版发布继续保持挂起状态。
