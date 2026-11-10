# Android 手机 / 平板 0.5.13

- 发布平台：Android 手机 / 平板（`android-mobile`）
- 版本：`0.5.13`（`versionCode 63`）
- 发布日期：2026-11-09
- 安装包：`MarcoMovie-0.5.13-android-mobile.apk`（兼容旧名：`MarcoMovie-0.5.13-mobile.apk`）

## 本次优化与修复

1. **分类页下滑刷新保持当前分类，不再弹回「推荐」页**：
   - 在首页选择「电影」「剧集」「综艺」「动漫」或其他分类后，顶部下拉刷新（`下滑刷新`）直接重新拉取当前所选分类与筛选条件的第 1 页内容，不会重置回「推荐」页。
   - 跨页面重绘（如屏幕旋转、状态栏尺寸变更或返回首页）时按当前片源保持已选分类（`selectedCategoryId`）、筛选条件（`selectedFilters`）与分类胶囊栏横向滚动位置（`cachedCatScrollX`），仅在切换不同片源时重置为「推荐」。
   - 下滑加载更多分页（`page > 1`）时不再重建分类胶囊栏并锁定列表纵向滚动偏移，避免分类栏或页面滚动位置跳回顶部。

## 验证范围

- 通过 `ReviewFixChecks`、`UpdateLayoutChecks`、`test_android_update_packages.py` 与 `check_public_content.py` 本地校验。
- 通过 `build_android.py` 正式签名与对齐校验。
