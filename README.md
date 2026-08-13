# 📚 番茄猫下载器 · 番茄/七猫小说下载 + 短剧IP助手

> **免费小说下载器** 与 **短剧创作/编剧辅助工具** 二合一(番茄猫下载器) —— macOS 原生应用。
> 既能把**番茄小说、七猫小说**一键下载成 **TXT / EPUB** 到本地,又能检索**番茄短剧后台的 IP 改编信息**,帮你判断哪些小说被改编成了**竖屏短剧/微短剧**、申请热度如何。

[![macOS](https://img.shields.io/badge/platform-macOS%20arm64-lightgrey)](https://github.com/YUKI0104/novel-downloader)
[![License](https://img.shields.io/badge/license-MIT-blue)](https://github.com/YUKI0104/novel-downloader)
[![Wails v2](https://img.shields.io/badge/Wails-v2-blueviolet)](https://wails.io)

基于 [Wails v2](https://wails.io)(Go + 原生 WebKit),内核纯 Go,零 Python 依赖;
番茄平台内置 [Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader)(Rust) 服务。
界面采用 Apple / macOS 原生设计语言,毛玻璃材质、明暗双模式自动适配。

---

## 🎯 这款软件适合谁?

### 📖 小说读者 / 下载党
- 想把喜欢的**番茄小说 / 七猫小说**保存到本地,**离线阅读**、导入自己的阅读器或做备份?
- 想一键浏览**两大平台的热门排行榜**(番茄综合/男频/女频 + 分类;七猫男生/女生 × 大热/新书/完结/收藏/更新)?
- 想在多设备间自由管理自己的阅读素材?

→ 本软件**完全免费**,支持一键搜索 → 下载 → 本地阅读。

### 🎬 短剧创作者 / 编剧
- 想找**适合改编成短剧的小说 IP**?
- 想知道某本小说是否已被**改编成短剧 / 微短剧**、**多少人申请过这个 IP**、**同 IP 改编中项目**有多少?
- 想按**改编方向(动漫短剧/真人短剧)、频道、分类、字数、完结状态、热门书单**筛选番茄 IP?

→ 本软件可直接检索**番茄短剧创作者中心后台**,把这些数据摆在你面前。

---

## ✨ 功能一览

### 🖼 界面一览
- **搜索页(唯一主页面)**:顶部「📂 下载」「⚙️ 设置」按钮;下方默认显示排行榜,搜索后切换为结果
- **书籍详情弹窗**:封面、简介、统计(评分/字数/热度/榜单/主角)、下载按钮、短剧IP数据条(可选)
- **下载管理弹窗**:已下载文件列表 + 刷新 / 打开目录 / 删除
- **设置悬浮菜单**:下载目录、保存格式、短剧模式开关

### 小说下载
- 🔍 **双平台搜索**:番茄小说、七猫小说,搜索即得封面、评分、字数、人气
- 🏆 **排行榜选书**:番茄(综合/男频/女频 + 阅读榜·新书榜 + 分类题材)、七猫(男生/女生 × 大热/新书/完结/收藏/更新),缓存 60s 秒开
- 📖 **书籍详情**:作者、简介、章数、评分、字数、热度、榜单、分类、主角
- ⬇️ **一键下载**:**TXT / EPUB** 两种格式,实时进度(章数百分比),默认存到下载文件夹
- 📂 **下载管理**:顶部「📂 下载」按钮查看已下载文件,支持 Finder 定位、删除(仅移除记录或连文件一起删)
- 📱 **本地阅读**:下载的 TXT/EPUB 可导入任意阅读器 / Kindle / 本地书架,离线阅读

**📥 下载使用流程:**

```
1. 打开 App —— 搜索页默认显示热门排行榜
2. 选平台(番茄小说 / 七猫小说)→ 输入书名 → 搜索
3. 点开书籍详情 → 点「下载」→ 实时查看进度
4. 完成自动存入下载文件夹;顶部「📂 下载」管理已下载文件
```

### 短剧 IP 检索
- 🎬 **改编书单**:七猫频道下查看官方「剧本改编书单」,含**改编方向 / 频道 / 分类 / 字数 / 完结 / 热门书单**六组筛选 + 分页
- 🔎 **短剧后台搜索**:打开**番茄书籍详情时自动查询**短剧创作者中心后台 IP,在简介与下载按钮之间显示「📅上架 / 👥申请 / 🎬改编中」

> 🔐 **登录态说明**:短剧后台数据需要登录权限,本软件会**自动检测本机已登录的浏览器会话**。
> 支持 **Chrome、Edge、Brave、Vivaldi、Opera**(均为 Chromium 内核,任一登录即可)。
> **不支持 Safari**。若以上浏览器均未登录 `www.shortdramas.com`,打开番茄详情时会显示**橙色提示条**引导登录。
>
> 🔑 **首次使用若弹出「security 想要访问钥匙串」**:
> 这是 macOS 在询问是否允许读取浏览器的钥匙串密钥(用于解密登录态)。请在弹出的对话框中点**「总是允许」**,一次即可,之后不再弹出。
> 若弹窗反复出现或卡住:打开「终端」运行一次 `security set-key-partition-list -S apple-tool:,apple: -s -k <你的开机密码> login`(把 `<你的开机密码>` 换成 macOS 登录密码),把 `security` 命令加入授权列表后即一劳永逸。

### 体验
- 🧭 **极简界面**:仅一个搜索页;「📂 下载」「⚙️ 设置」为顶部按钮,点击弹出管理弹窗/悬浮菜单
- ⚙️ **设置悬浮菜单**:下载目录(点击选文件夹)、保存格式(TXT/EPUB)、**短剧模式开关**
- 📐 固定窗口(1100×780),明暗双模式跟随系统

---

## 🚀 快速上手

1. **下载**:从 [Releases](https://github.com/YUKI0104/novel-downloader/releases) 获取 `FanQieMao-Downloader-v1.2.2.dmg`(macOS 通用:Apple 芯片与 Intel 均可)。
2. **安装**:打开 DMG,把 App 拖入「应用程序」。因未签名,首次打开请右键 →「打开」,或执行 `xattr -cr /Applications/番茄猫下载器.app`。
3. **下载小说**:在搜索页搜书名 → 点开详情 → 下载。默认存到 `~/Downloads`;顶部「📂 下载」按钮管理已下载文件。
4. **短剧 IP**(可选):首次进入会询问是否启用。启用后需先在 **Chrome / Edge / Brave / Vivaldi / Opera** 任一浏览器登录 `www.shortdramas.com`(番茄短剧创作者中心),本软件会自动检测并读取该登录态。

> - 短剧 IP 功能可在「⚙️ 设置」悬浮菜单里随时开关;**关闭后**,番茄详情的短剧数据、七猫的改编书单都会隐藏。
> - 短剧后台搜索依赖浏览器的登录会话;以上浏览器都没登录时,打开番茄详情会显示提示条引导登录。Safari 暂不支持。

---

## 🏗 项目结构

```
novel-downloader-wails/
├── main.go            # Wails 入口(固定窗口 1100×780)
├── app.go             # 绑定层:搜索 / 详情 / 榜单 / 下载 / 设置 / 环境
├── shortdrama.go      # 短剧后台搜索(读 Edge 登录态 + 调 shortdramas IP 接口)
├── app_test.go        # headless 端到端测试(go test,会真连各平台 API)
├── qimao/             # 七猫下载器(签名 API + AES 解密 + 官网榜单接口)
├── fanqie/            # 番茄下载器(管理 Rust 内核服务 + 官网榜单解析)
├── frontend/          # Vite + 原生 JS 前端(Apple 风格)
│   ├── index.html
│   └── src/main.js, style.css
├── scripts/build.sh   # 构建脚本(打包番茄内核)
└── build/             # 构建产物(build/bin/番茄猫下载器.app)
```

## 🔨 构建

前置:Go 1.25+、[Wails CLI](https://wails.io/docs/gettingstarted/installation)、Node.js。
番茄内核置于 `~/bin/Tomato-Novel-Downloader`(或设置 `TOMATO_BIN` 环境变量)。

```bash
cd novel-downloader-wails
./scripts/build.sh
```

产物:`build/bin/番茄猫下载器.app`(约 17 MB,自包含番茄内核)。

## 🧪 开发 / 测试

```bash
wails dev      # 热重载开发模式
go test -run TestE2E -v   # 无 GUI 的逻辑链路测试(会真连七猫/番茄 API)
```

## 📦 分发给他人

1. 打包 `番茄猫下载器.app`(macOS arm64)。
2. 因仅自签名,首次打开需右键 →「打开」,或执行 `xattr -cr 番茄猫下载器.app`。
3. 若要完全规避提示,需要 Apple 开发者账号做签名 + 公证(notarytool)。

> App 与番茄内核均为 **通用二进制**(arm64 + x86_64),Intel 和 Apple Silicon 都能直接运行。

## 🗄 数据目录

- 设置:`~/Library/Application Support/novel-downloader/settings.json`
- 下载记录:`~/Library/Application Support/novel-downloader/downloads.json`
- 番茄服务配置:`~/Library/Caches/tomato-novel-downloader/config.yml`
- 默认下载目录:`~/Downloads`(直接下载到「下载」文件夹)

## 🔧 技术备注

- **七猫 API**:MD5 签名(`sign`)+ Dart hashCode 模拟 + AES-128-CBC 解密,均为 Go 原生实现;
  榜单走官网 web 接口 `www.qimao.com/qimaoapi/api/rank/book-list`(无需签名,参数 `is_girl` + `rank_type`)。
- **番茄 API**:通过 Rust 服务 `127.0.0.1:18423` 的 REST 接口;榜单抓官网 `/rank` 页(分类导航),
  因官网书名被自定义字体混淆(PUA 私用区字符),榜单需经内核解码书名,已做并发 + 缓存优化。
- **短剧后台搜索**:读 Edge cookie 库解密 `sessionid`(keychain 密钥 + PBKDF2("saltysalt",1003) + AES-128-CBC
  + 库版本≥24 去 32 字节前缀),调 `www.shortdramas.com/api/origin/cp/playlet/ip/list` 按书名搜番茄 IP。
  需先在 Edge 登录过 `shortdramas.com` 并保持会话有效。
- **关键坑**:`http.Client{Timeout: 60}` 是 **60 纳秒**而非 60 秒,必须写 `60 * time.Second`。

## ⚠️ Windows 移植说明(供有需要的开发者)

本项目**只支持 macOS**(arm64 + x86_64 通用二进制),暂不原生支持 Windows。
Wails v2 本身支持 Windows(基于 WebView2/Edge Chromium),番茄内核也有官方 Win64 版本,因此**理论上可移植**,但有以下几处 macOS 专属逻辑需要改造:

| 位置 | 文件 | macOS 现状 | Windows 需要 |
|---|---|---|---|
| 用户主目录 | `app.go` / `shortdrama.go` / `fanqie.go` | `os.Getenv("HOME")` | `os.UserHomeDir()`(Windows 为 `%USERPROFILE%`) |
| 打开文件夹 | `app.go` | `exec.Command("open", path)` | `explorer`(如 `explorer /select, <path>`) |
| 数据/缓存目录 | `app.go` / `fanqie.go` | `~/Library/Application Support/...` | `%APPDATA%` / `%LOCALAPPDATA%` |
| 番茄内核路径 | `app.go` / `fanqie.go` | `~/bin/Tomato-Novel-Downloader` | `TomatoNovelDownloader-Win64-v2.4.13.exe`(官方有 Win64 版) |
| PID 文件 | `fanqie.go` | `/tmp/tomato-server.pid` | `os.TempDir()` |
| **Edge cookie 解密** | `shortdrama.go` | keychain(`security`)+ PBKDF2 + AES | **DPAPI**(`CryptUnprotectData`)+ 读取 `Local State` 的 `os_crypt.encrypted_key` 解密出密钥,再 AES-128-CBC 解 cookie |

**移植建议**:
- 用 Go **build tag**(`//go:build windows` / `//go:build !windows`)写平台专属文件,不破坏 macOS 版。
- 下载核心(搜索 / 榜单 / 改编书单 / 下载)基本是纯移植,主要改路径与 `open` 命令。
- **短剧后台检索**依赖 Edge 会话解密,Windows 端需要 DPAPI 实现(注意 Windows 下 cookie 加密结构:Local State 里的密钥先 DPAPI 解密,再解 v10 cookie,库版本 ≥ 24 同样要去 32 字节前缀)。
- Windows 构建:`wails build -platform windows/amd64`(需 Windows 环境或交叉编译工具链)。

欢迎有能力、有 Windows 环境的开发者 Fork 后自行移植修改与测试。

## 🙏 致谢

本项目在开发过程中参考 / 复用了以下开源项目,在此致以诚挚感谢:

- [**shing-yu/swiftcat-downloader-flutter**](https://github.com/shing-yu/swiftcat-downloader-flutter.git) —— 七猫小说下载器(swiftcat),本项目的七猫 API 签名、AES 解密及下载逻辑移植自其思路。
- [**zhongbai2333/Tomato-Novel-Downloader**](https://github.com/zhongbai2333/Tomato-Novel-Downloader.git) —— 番茄小说下载内核(Rust),本项目番茄平台的搜索 / 下载 / 详情由该内核的本地 REST 服务驱动。
