# M3-e 任务书 — 换软件图标

用户给了图标源：`/Users/yuki/Downloads/AppIcon.appiconset`（他明确指定就用这一份）。

## 现状
- 工程里**完全没有资源目录**（`find . -name '*.xcassets'` 空），`project.pbxproj` 里却写着 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`（第 612、633 行）→ 现在 app 用的是系统默认空白图标。
- 源目录里 10 个 macOS 图标尺寸齐全、像素尺寸**已逐一核对正确**：
  16x16/16@2x/32/32@2x/128/128@2x/256/256@2x/512/512@2x（1024×1024）—— 文件名 `icon_<size>.png`，`Contents.json` 的 `idiom` 全是 `mac`，可直接用。
- 同一目录里另有 `Icon-App-*`（iOS 风格 + `-1` 重复文件）是导出工具留下的**垃圾，不要拷进来**。

## 要做的
1. 建 `Sources/Resources/Assets.xcassets/AppIcon.appiconset/`，只放那 10 个 `icon_*.png` + `Contents.json`（`Contents.json` 原样拷，`info.author` 可留 xcode）。
2. 让工程真的用上：`project.yml` 里加资源目录并 `xcodegen generate`（登记进 `project.pbxproj`）；确认 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 生效、无需改其它构建设置。
3. 构建后核验产物：`<app>/Contents/Resources/AppIcon.icns` 存在 且 含 1024×1024（`iconutil`/`sips` 查一下）；app 的 `CFBundleIconFile`（或 icns 默认名）能对上。
4. 交付截图：**Dock 里/访达里的新图标**（小尺寸 16/32 也要看得出是什么东西，别糊成一团）+ 关于面板（若显示图标）。
5. 回归：窗口 1000×800、卡片 176.8×293.0（10 张全等）、弹窗 950×600、左右留白 30/30 都不许变；`chain` 绿。

## 注意
- 图标不影响 `Info.plist` 其它项；别顺手改 bundle id / 版本号 / 窗口设置。
- 用户很在意"图标是不是真的换上了"，**必须贴出观感证据**（Dock 截图），不要只说 BUILD SUCCEEDED。
- 跑自检纪律同前：先 `ps aux | grep FanQieMao` 看实例，只跑必要轮次，跑完 `bash Tools/跑.sh` 留在普通启动；settings 还原（`shortdramaIgnored=true`、`prompted=true`）、平台＝番茄。
