# 番茄猫 · 原生版规格 v0.1

> 目标：把现有的 Wails 版「番茄猫下载器」（Go + WebKit + Rust 内核）重做成原生 macOS App（Swift + SwiftUI + Xcode 工程），
> 并把这次踩到的两类问题（内核被自己的"热补丁"自更新打成死循环、退出留残留进程）在架构上根治。
> 分工：pi 实现，Hermes 写规格与验收，用户按界面观感验收。
> 决策记录（2026-10-09，用户逐条拍板）：Q1 甲 全量原生重写、Q2 甲 保留 Rust 内核当本地服务、Q3 甲 短剧 IP 放第二批、
> Q4 甲 新版独立名字与 bundle id 与旧版并存、Q5 甲 旧版那轮审计修完、Q6 甲 内核更新静默自动、Q7 甲 更新失败不弹窗只在设置页留灰字。

---

## 0. 一句话架构

原生 App 自己实现搜索/详情/榜单/下载/设置/库管理（Swift），番茄平台继续用官方 Rust 内核
（Tomato-Novel-Downloader v2.4.x，本地 `127.0.0.1:18423` 的 REST 服务）拿数据；
App 负责内核的**放置、启动、健康探测、自动更新、退出清理**。

## 1. 范围

### 阶段 M1（骨架，先上机看观感）
- 番茄：搜索（书名 / 纯数字 ID / 书页链接直达）、书籍详情、下载 TXT（真实进度）、下载管理（Finder 定位、删除记录或连文件删）
- 设置：下载目录选择、保存格式（TXT）、内核版本行（灰字）、导出诊断日志
- 内核：定位 / 启动 / 健康探测 / 退出清理 / 自动更新（第 5、6 节，本阶段就要做，这是本次事故的根治）
- 界面：**Liquid Glass 设计语言**（第 7 节，2026-10-09 用户追加要求）；单搜索页 + 顶部动作；明暗双模式自动；**窗口尺寸固定 1000×800、不可调整**（2026-10-09 用户要求：绿色按钮/拖边框/双击标题栏都不得改变尺寸，位置可拖、红叉可关）

### 阶段 M2
- 七猫：搜索 / 详情 / 下载 / 榜单 / 改编书单
- 番茄排行榜（综合/男频/女频、阅读榜·新书榜、分类题材）
- EPUB 导出（沿用现有中文 EPUB 2.0 结构）

### 阶段 M3
- 短剧 IP：读本机 Chromium 系浏览器登录态（AES + PBKDF2 解开 cookie）、番茄详情里的 IP 数据条、七猫改编书单联动
- 打磨、图标、签名/公证准备（如需要）

### 非目标
- 不做 Windows 移植；不做账号体系；不改番茄/七猫的接口协议；不自己实现番茄解析（明确用内核）

## 2. 工程与命名
- 目录：`~/Documents/FanQieMao`（Xcode 工程 + `docs/spec-v0.1.md` 等文档）
- 显示名：番茄猫；bundle id：`com.yuki.fanqiemao`（与旧版 `com.wails.番茄猫下载器` 并存，验收满意后再删旧版）
- 最低系统：与现有 Xcode 27 工具链一致（macOS 14+）；Swift 6 / SwiftUI，不引第三方依赖（如必须，先说明理由）
- 数据沿用（保证老记录可见）：
  - 设置 `~/Library/Application Support/novel-downloader/settings.json`
  - 下载记录 `~/Library/Application Support/novel-downloader/downloads.json`
  - 内核数据 `~/Library/Caches/tomato-novel-downloader/`（config.yml / logs / download_history.jsonl）
  - 下载文件名与旧版一致：`书名 作者 [ID].txt`

## 3. 唯一写入口
所有落盘（设置、下载记录、库操作）只经过 `LibraryStore` 与 `SettingsStore` 两个类型；
UI 与 Service 不各自写文件。目的：避免"记录说下载了、磁盘上没有"这类不一致。

## 4. 代码结构（M1）
```
FanQieMao/
  FanQieMaoApp.swift        # @main, WindowGroup, 场景/生命周期钩子
  Core/
    Kernel/
      KernelLocator.swift   # 解析用哪一个内核二进制（第 5.1 节顺序）
      KernelManager.swift   # 启动/健康探测/停止/杀进程组/孤儿清理（第 5.2~5.4 节）
      KernelUpdater.swift   # 版本检查、下载、校验、原子替换、回滚（第 6 节）
      KernelService.swift   # REST 客户端：/api/status|search|preview|jobs|library（含等待重启的重试）
    Fanqie/
      FanqieSearch.swift FanqieBookInfo.swift FanqieDownload.swift
    Network/HttpClient.swift   # 统一超时、重试策略、并发上限
    Store/LibraryStore.swift SettingsStore.swift
  Features/
    Search/   详情/    Downloads/    Settings/
  Models/
```

## 5. 内核生命周期（本次事故的根治）

### 5.1 用哪个内核（顺序，先命中先用）
1. 用户显式指定路径（设置里可留空）
2. `~/Library/Application Support/FanQieMao/kernel/current`（自动更新的落点）
3. 包内出厂备份 `Contents/Resources/Kernel/TomatoNovelDownloader-macOS_arm64`（arm64 机器）或 `..._amd64`（Intel）
   —— **出厂文件必须是官方发布包原样文件，禁止 lipo、禁止改字节**（原因见 6.1）

### 5.2 首次运行
把出厂内核复制到 `~/Library/Application Support/FanQieMao/kernel/<version>/TomatoNovelDownloader`，
`chmod 755`，并把 `current` 指向它；包内那份之后只做出厂回滚用。**不要写进 .app 包内**（破坏签名 + /Applications 写权限）。

### 5.3 启动与健康
- 参数：`--server --data-dir ~/Library/Caches/tomato-novel-downloader`
- 以**独立进程组**启动（Swift `Process` 启动后记录 pid；杀的时候按进程组杀：`kill(-pid, SIGTERM)`，必要时 SIGKILL）
- 健康探测：`GET /api/status`（2s 超时）。冷启动最多等 60s（本机实测官方原样内核 ~2s 就绪）
- **前端等待期行为**：内核未就绪/正在重启时，界面显示「内核正在启动/更新…」这类状态，**不允许把 `connect refused` 直接抛成"详情加载失败"**（这次用户看到的就是这个）
- 请求重试：对内核 REST 请求遇到连接被拒/连接重置时，退避重试（0.5s/1s/2s/3s，最多 4 次），期间界面保持"进行中"

### 5.4 退出与孤儿清理
- 退出路径（关窗、Cmd+Q、崩溃后重启）都必须不留内核进程：
  - 正常退出：`applicationWillTerminate` 杀进程组（SIGTERM → 等 3s → SIGKILL），删除 pid 文件
  - 启动时清理：若 18423 端口有属主，且不是本 App 本次启动的进程 → 视为孤儿/陌生内核，先尝试 `GET /api/status` 记录版本，然后杀掉并重新拉起自己的
  - pid 文件（`~/Library/Caches/tomato-novel-downloader/…` 或 App Support）仅作辅助，不当作唯一依据
- 验收：三种退出路径后 `ps` 无任何 `TomatoNovelDownloader*` 残留

## 6. 内核自动更新（Q6 甲：静默自动；Q7 甲：失败只留灰字）

### 6.1 为什么要"原样文件 + 不改字节"
内核启动时会拿自身文件的 SHA256 与官方发布包比对，不一致就判"热补丁"→ 下载 → 替换 → **重启自己**（重启的几秒端口关闭，前端就报连接失败）。
lipo 合成的通用二进制永远对不上 → 每次启动都重复下载 8MB + 重启（已实测：日志里一轮出现 8 次以上「检测到热补丁」）。
因此：出厂内核按架构用官方原样文件，SHA 对得上，既消掉死循环，也不跟内核自身的自更新打架。

### 6.2 检查时机
- App 启动后 30s（后台，不阻塞界面）
- 之后每 24h 一次
- 内核启动失败/健康检查失败时，立刻查一次（可能是上游接口变化需要新内核）

### 6.3 更新流程
1. `GET https://api.github.com/repos/zhongbai2333/Tomato-Novel-Downloader/releases/latest` → `tag_name`
2. 与本地内核 `--version` 输出（形如 `Tomato Novel Downloader v2.4.15`）做语义化版本比较；不高于当前版本 → 结束
3. 按本机架构选 asset：
   - arm64 → `TomatoNovelDownloader-macOS_arm64-<tag>`
   - amd64 → `TomatoNovelDownloader-macOS_amd64-<tag>`
   下载地址 `https://github.com/zhongbai2333/Tomato-Novel-Downloader/releases/download/<tag>/<asset>`
4. 下载到临时目录 → `chmod 755` → **先执行 `--version` 校验能跑出预期版本号**（防止下到坏文件/404 HTML）→ 通过才继续
5. 原子替换：新版本放 `kernel/<新版本>/`，更新 `current` 指针（先 `current.new` 再 rename）
6. 重启内核 → 60s 健康检查 → 失败则把 `current` 回滚到上一个可用版本并重启，记录日志
7. 保留策略：最近 2 个版本 + 包内出厂版；更旧的删除

### 6.4 网络与失败处理（Q7 甲）
- 直连 `github.com` / `api.github.com`；失败时依次尝试加速镜像（如 `ghfast.top`、`ghproxy` 风格前缀）与用户系统代理
- 仍然失败：**静默放弃**，继续用现有内核；只把结果写进设置页的灰字状态行与本地日志，**不弹窗、不阻塞、不打扰**
- 现有内核能跑就绝不因为"更新失败"影响使用

### 6.5 界面呈现（只一行，不堆按钮）
设置页一行灰字示例：`番茄内核 v2.4.15 · 已是最新（16:08 检查）` / `番茄内核 v2.4.15 · 更新检查失败，仍在使用当前版本`。
不新增"更新内核"按钮（静默自动已覆盖）；不弹更新提示。

## 7. UI 规格（Liquid Glass 设计语言）

用户口径（2026-10-09）：**界面要重新设计，用 Liquid Glass。**
追加决策（同日用户拍板）：**Q8 乙 —— 整窗玻璃化（窗口背景也是玻璃）；Q9 甲 —— 搜索→详情用 matchedGeometry 玻璃形变。**
> 乙 的落地红线：整窗玻璃可以，但**内容必须仍然读得清**。做法是玻璃铺在窗口背景与控件层，结果列表/详情正文坐在足够不透明的材质面上（实测发花就加大不透明度），字号用系统层级、不做小字装饰。凡是玻璃导致文字对比不足的地方，直接改回不透明材质，不用提示文字补救。
已在本机 SDK 核实可用（MacOSX27.0.sdk，不是凭记忆）：
- SwiftUICore：`glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())`、`Glass.regular/.clear/.identity`、`Glass.tint(_:)`、`Glass.interactive(_:)`、`GlassEffectContainer`、`glassEffectID(_:in:)`、`glassEffectUnion(id:namespace:)`、`glassEffectTransition(_:)`（`.matchedGeometry` / `.materialize` / `.identity`）
- SwiftUI：`.buttonStyle(.glass)`、`.buttonStyle(.glassProminent)`（`GlassButtonStyle` / `GlassProminentButtonStyle`）

设计原则（"信息看得懂"优先，玻璃不能牺牲可读性）：
1. 玻璃只用在**控件层**：顶栏、浮层、按钮、状态胶囊、进度条。内容层（搜索结果列表、详情正文、章节列表）用系统材质/纯色底——整屏玻璃会让文字发花，用户明确反感看不清。
2. 同一组控件放进一个 `GlassEffectContainer`（顶栏：平台切换 + 搜索框 + 「下载」「设置」），组内用 `glassEffectID` 让玻璃形变衔接、不各闪各的。
3. 按钮分级：主操作（下载）`.glassProminent`；次级（复制 ID、复制链接、打开目录）`.glass`；危险（删除记录/文件）红色 tint 的玻璃按钮。
4. 浮层（详情、下载管理、设置）= 玻璃卡片 + 大圆角形状，进出用 `glassEffectTransition(.materialize)`；不用旧版那种朴素弹窗。
5. 搜索 → 详情：同一 `namespace` + `glassEffectID`，用 `.matchedGeometry` 让选中的书卡从列表位置变形展开成详情卡（这是 Liquid Glass 的标志性动效，也是"点哪儿开到哪儿"的空间连续感）。
6. 内核状态（启动中 / 更新中 / 就绪）用顶栏玻璃胶囊显示，不用弹窗（与第 5.3、6.5 的"不打断"一致）。
7. 深浅色跟随系统（Liquid Glass 自带适配）；强调色用番茄红，警示用系统橙；字号用系统层级字体（`.headline` / `.subheadline` / `.caption`），不手工调字号。
8. 窗口尺寸固定 1000×800、不可调整（拖边框/绿色按钮/双击标题栏均无效）；元素自解释——入口语义不清就删掉并把功能并进语义明确的位置，不加提示文字补救。

信息架构（沿用旧版，按用户口径收紧）：
- 单页搜索窗：顶栏为平台切换（番茄；七猫 M2 加入）+ 搜索框 + 「下载」「设置」；默认显示排行榜（M2）
- 详情：封面、书名、作者、简介、章数/字数/评分/热度、小说 ID 与书籍链接（均一键复制）、下载按钮（含真实进度）
- 全中文短句；空状态、失败状态都要有一句话说明与一个明确动作（不能只显示报错原文）

## 8. 验收清单（Hermes 跑，不接受"我看着对"）
M1 交付时逐条给证据：
1. `xcodebuild -scheme FanQieMao -configuration Release build` 通过（贴命令与结果）
2. 冷启动到可搜索 ≤ 5s（记时间戳）
3. 搜索「游走神话时代」出结果；纯数字 ID 与书页链接能直达
4. 详情页出数据（含 ID 与链接复制），不再出现 `connection refused` 类报错
5. 下载一本（限前 3 章即可）产出 `书名 作者 [ID].txt`，文件真实存在且大小 > 0
6. 退出验收：关窗 / Cmd+Q / 强杀后 `ps` 无内核残留；再启动不复用陌生内核
7. 更新验收：伪造一个"本地版本 < 远端"的场景（可临时改比较逻辑或指向一个已知高版本 tag 的 mock），验证 下载→校验→替换→重启→健康 全链，以及健康失败时自动回滚
8. `git status` 干净：没有动不该动的文件（旧仓库、/Applications、用户下载目录）
9. **Liquid Glass 实际生效**：顶栏/浮层确有 `glassEffect` + `GlassEffectContainer`，搜索→详情有 `matchedGeometry` 形变；给我可核对的证据（源码位置 + 我按界面/AX 读回验证），不接受"看起来像"

## 9. 风险与已知边界
- 上游改接口：我们只能靠"更新更快 + 失败回滚"，不能预防；内核自带的"热补丁"机制正是为这种场景设计的，不要关掉
- GitHub 直连在国内不稳定：镜像与静默失败是硬要求
- 短剧 IP 需要浏览器登录态与钥匙串授权（M3 再做，届时单独定流程）
- 七猫签名/AES 逻辑照搬现实现，不加不改
