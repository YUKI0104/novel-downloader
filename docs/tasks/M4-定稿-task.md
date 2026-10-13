# M4 任务书 — 定稿收尾 + 打干净版进「应用程序」（等用户点头后开工）

依据：`docs/定稿清单.md`（用户原话：「游走神话时代这个就是测试的时候给你留着，测试完定稿了要删掉这个」）。
本任务书把清单落到可执行步骤，并预先做了清点（**不许扩大删除范围**）。

## 1. 界面里的测试残留（必删）
- `Sources/Features/Search/SearchView.swift:57-59`：空状态里的「试搜「游走神话时代」」按钮 + 它把 `model.searchText` 写成「游走神话时代」的那两行。
  删掉后空状态只留：图标 + 「输入书名开始搜索」+ 一行说明（说明里可以保留「也可以直接粘贴 10 位以上的书籍 ID，或 fanqienovel.com 的书页链接。」）。
- 全仓复核：`grep -rn '游走神话时代' Sources --include=*.swift` 只允许剩 `KernelSelfTest.swift`（自检钩子，环境变量触发、不进正常界面）。**当前实测：18 处在 KernelSelfTest，2 处在 SearchView（本项要删的）。**

## 2. 测试产物（只删可归属为测试的，用户自己的书一律不动）
- `~/Downloads/游走神话时代，开局拜师道门天师 六个大脑瓜 [7673521851523419198].txt`（自检产物）
- `~/Downloads/游走神话时代，开局拜师道门天师 六个大脑瓜 [7673521851523419198]-2.txt`（旧自检产物）
- **不要动**：`花妖军嫂种出万亩绿洲…`（用户 9/27 真下载）、`全球灾变之末日游戏…`、`我在乱世靠换装系统装神女…`、`玄幻：开局无敌…`、`霸王花…` 以及所有 `*细纲*`/`正文*` 之类的编剧文件——那些不是测试产物。
- `~/Library/Application Support/novel-downloader/downloads.json`：删掉 title 为「游走神话时代，开局拜师道门天师」的记录（有多条、时间集中在 10/10 23:42 与 10/11），**只保留用户真实记录**（`花妖军嫂种出万亩绿洲，系统崩了` / 2026-09-27）。改前先把原文件备份到 `/tmp/`（不备份进包）。
- 内核数据目录（`~/Library/Caches/tomato-novel-downloader/`）里的日志/历史：确认没有用户可见的测试噪音，需要删的先列清单给 Hermes 过目。

## 3. 调试开关自证
- 证明**正常启动不打印任何调试/自检信息**：`bash Tools/跑.sh` 正常启动后，`~/Library/Application Support/FanQieMao/logs/app.log` 里不应出现 `FQM_SELFTEST`、`M3G`、`M3D ①` 之类的自检行（正常启动只允许普通运行日志）。贴日志片段。
- `FQM_SELFTEST` / `FQM_DEBUG_METRICS` 等环境变量开关保留（不进界面、不影响正常使用）。

## 4. 打干净版进「应用程序」+ 装
- 用 `Tools/打包.sh`（如无则新建：Release 构建 → 自签名（FanQieMao Dev，本机证书）→ 拷到 `/Applications/番茄猫.app`），**与旧版 `com.wails.番茄猫下载器` 并存**，不动旧版。
- 装完自证：`codesign -dv` 显示 Authority=FanQieMao Dev；`/Applications/番茄猫.app` 图标正确；双击能起（用 `open` 起，起完留在正常状态）；窗口 1000×800。
- **Spotlight/访达里只能有 1 份「番茄猫」**（用户对重复条目零容忍）：查 `mdfind -name '番茄猫'` 与 `/Applications`，若有重复条目清掉并在报告里说明。
- 版本信息：`CFBundleShortVersionString` 定为 `1.0.0`（旧版并存，bundle id 不变 `com.yuki.fanqiemao`）。

## 5. 交回
1. 改动/删除清单（逐条含绝对路径）+ 删前备份位置；2. 定稿后的空状态截图（无「试搜」按钮）+ `/Applications/番茄猫.app` 在访达里的截图 + `codesign -dv` 输出；3. 正常启动日志无自检字样；4. `chain` 回归绿（注意：chain 会往 ~/Downloads 写测试 txt，跑完**再清一次**并说明）。
