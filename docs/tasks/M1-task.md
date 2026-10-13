# M1 任务书 · 「番茄猫」原生版骨架（Liquid Glass）

规格：`/Users/yuki/Documents/FanQieMao/docs/spec-v0.1.md`（**先读它**，尤其第 4、5、6、7 节）
你的交付：一个能上机的原生 App 骨架（搜索 / 详情 / 下载 / 设置 / 下载管理 + 内核生命周期 + 内核自动更新），Liquid Glass 界面。
一句话：**这次事故的两类问题（内核自杀循环、退出留孤儿）必须在架构里根治**，其余按规格。

## 0. 环境（本机已就绪，不用装东西）
- Xcode 27.0（`/Applications/Xcode.app`），`xcodebuild` 可用；SDK：MacOSX27.0.sdk
- 工程目录：`~/Documents/FanQieMao`（本任务书就在 `docs/tasks/`）
- 出厂内核（**直接用这两个，不许 lipo、不许改字节**，SHA 必须保持）：
  - arm64：https://github.com/zhongbai2333/Tomato-Novel-Downloader/releases/download/v2.4.15/TomatoNovelDownloader-macOS_arm64-v2.4.15
    sha256 `cc49e2dcb40f22971eeef317a395f4f165425d57e8685bfab1e9ebc8592abf43`
  - amd64：`.../TomatoNovelDownloader-macOS_amd64-v2.4.15`，sha256 `a786733991501b15bb5190c7d45e4a918d86e051ea259d967e61222835288e1f`
  - 本机已下载好：`/tmp/official-arm64`、`/tmp/official-amd64`（可直接拷）
  - 放进 App 包 `Contents/Resources/Kernel/`，按架构命名 `TomatoNovelDownloader-macOS_arm64` / `_amd64`

## 0.5 逻辑来源：照搬现成代码（不要重新设计）

现成实现就在 `~/code/novel-downloader`（Wails 版，已修好、已推送）——**逐文件对照移植，不是重新发明**。
设计空间越小，越快越不容易跑偏：

| 现成文件 | 搬到 Swift 后 | 要照搬的内容 |
|---|---|---|
| `fanqie/fanqie.go`（1167 行） | `Core/Fanqie/FanqieAPI.swift` | `/api/status`、`/api/search?q=`、`/api/preview/<id>`、`/api/preview-cover/<hash>`、`/api/jobs`(POST 建/GET 查)、`/api/library` 的调用方式与字段解析、超时与重试策略、网页书名缓存 |
| `app.go`（737 行） | ViewModel 层 | Search / BookInfo / Download / Library / Settings 的编排、错误话术（用户可见文案照抄） |
| `covers.go` / `log.go` | 封面抓取 / 日志 | 超时、落盘路径、日志格式 |
| `fanqie/fanqie.go` 的 EnsureServer / StopServer / adoptRunningLocked / looksLikeKernel / pidListeningOnPort / killProcess | `Core/Kernel/**` | 内核定位顺序、接管孤儿、整组回收、只杀像内核的 PID 这些**已修好的语义**，逐条照做 |
| `frontend/src/main.js` + `index.html` | `Features/**` | 界面字段、文案、交互顺序（界面视觉按 Liquid Glass 重画，字段与话术保持一致） |

M1 不做的（现成有但留给 M2/M3）：七猫 `qimao/**`、短剧 `shortdrama.go`、`fanqie/cookies.go`、EPUB 导出。

## 1. 必做（M1）
1. **工程与构建**：SwiftUI App，bundle id `com.yuki.fanqiemao`，显示名「番茄猫」，最小 macOS 14；
   `xcodebuild -scheme FanQieMao -configuration Release build` 一条命令能出 `.app`（产物路径写进 README 或 `docs/`，我按它验收）。
2. **内核生命周期**（规格 5 节，逐条实现）：
   - 定位顺序：用户指定 > `~/Library/Application Support/FanQieMao/kernel/current` > 包内出厂（按架构）
   - 首次运行把出厂内核复制到 Application Support（可写），**绝不写 App 包内**
   - 启动：`--server --data-dir ~/Library/Caches/tomato-novel-downloader`；独立进程组；`/api/status` 健康探测（2s 超时，冷启动最多等 60s）
   - 退出：关窗 / Cmd+Q / `applicationWillTerminate` 三处都要杀进程组（SIGTERM→3s→SIGKILL）并清 pid 文件；启动时若端口被陌生/孤儿内核占用 → 接管并在退出时收干净
   - **内核未就绪/重启期间**：界面显示「内核正在启动/更新…」，不许把 `connection refused` 当错误抛给用户
3. **内核自动更新**（规格 6 节）：启动后 30s + 每 24h + 内核起不来时，查 `releases/latest` → 语义版本比较 →
   按架构下官方 asset → `chmod +x` → 先跑 `--version` 校验 → 原子替换到 `kernel/<版本>/` → 重启 → 60s 健康检查 →
   失败回滚上一个可用版本并保留最近 2 份 + 出厂版；GitHub 直连失败走镜像；**彻底失败就静默继续用旧内核**。
   设置页一行灰字显示版本与检查结果。
4. **番茄链路**：搜索（书名 / 纯数字 ID / 书页链接直达）、详情、下载 TXT（真实进度）、下载管理（Finder 定位 / 删除记录 / 连文件删）。
   接口与旧版一致：`/api/status`、`/api/search?q=`、`/api/preview/<id>`、`/api/jobs`（POST 建、GET 查）、`/api/library`、`/api/preview-cover/<hash>`；
   下载产物命名与旧版一致：`书名 作者 [ID].txt`；设置与下载记录沿用 `~/Library/Application Support/novel-downloader/{settings.json,downloads.json}`（要能读旧文件）。
5. **界面（Liquid Glass，规格第 7 节）**：用户已拍板 **Q8 乙（整窗玻璃化，窗口背景也是玻璃）+ Q9 甲（matchedGeometry 形变）**。
   窗口背景与控件层（顶栏、浮层、按钮、状态胶囊）用 `glassEffect` + `GlassEffectContainer`；内容层（结果列表、详情正文）坐在**足够不透明的材质面**上保证可读性（这是 乙 的硬红线，字发花就加不透明度，别硬上纯玻璃）；
   下载按钮 `.glassProminent`，次级动作 `.glass`；搜索→详情用同 namespace + `glassEffectID` + `matchedGeometry`；
   内核状态用顶栏玻璃胶囊；深浅色跟随系统；窗口最小 1000×700；全中文短句；空/失败状态要给一句话 + 一个明确动作。
6. **两个 Store 是唯一写盘入口**：`SettingsStore`、`LibraryStore`。

## 2. 不许做
- 不许 lipo/改字节内核；不许把内核写进 App 包内；不许给自己实现番茄接口（用内核 REST）
- 不许动 `/Applications/番茄猫下载器.app`、`~/code/novel-downloader`（旧仓库）、`~/Documents/FanQieMao/docs/**`（我的规格与任务书）
- 不许自己截屏/读图片验证界面（我会另做）；不许启动 `/Applications` 里的旧 App 占 18423 端口
- 不引第三方依赖（要引先说明理由）；不做短剧 IP、七猫、EPUB（那是 M2/M3）

## 3. 自己先验（交回时必须附证据）
- `xcodebuild ... build` 命令与输出尾部；`.app` 的绝对路径与大小
- **退出验收**：起 App → 点红叉 / Cmd+Q / `kill -9` App 三种情况，各贴 `ps -eo pid,ppid,command | grep -i tomato` 与 `lsof -nP -iTCP:18423 -sTCP:LISTEN` 的结果；`kill -9` 之后要验证"重开 App 会接管并收干净"
- **内核不自杀**：连起 3 次，每次日志里「检测到热补丁」次数必须为 0（`grep -c 热补丁 <data-dir>/logs/latest.log`）
- **更新链路**：用 mock（临时把远端 tag 指到一个更高版本号，或直接构造一个假 asset 目录）跑通 下载→校验→替换→重启→健康；再故意让健康检查失败，证明会回滚
- 搜索「游走神话时代」出结果；纯数字 ID 与书页链接直达；下载前 3 章产出真实文件（贴 `ls -l` 与大小）

## 4. 报告格式
1. 交付物路径 + 构建命令 + 通过证据
2. 逐条对照规格 5/6/7 节：实现位置（文件:行）+ 我复跑用的命令
3. Liquid Glass 实际用到的 API 清单与位置
4. 未完成 / 不确定 / 需要我决策的清单（不要写"基本完成"这种话）
