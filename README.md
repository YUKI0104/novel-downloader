# 📚 小说下载器 NovelDownloader

macOS 免费小说下载 GUI,支持**七猫小说**和**番茄小说**两大平台,自带**排行榜**浏览与**一键下载**。

基于 [Wails v2](https://wails.io)(Go + 原生 WebKit),内核纯 Go,零 Python 依赖;番茄平台内置
[Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader)(Rust) 服务。

界面采用 **Apple / macOS 原生设计语言**:系统字体、毛玻璃材质、Apple 蓝强调色、明暗双模式自动适配。

## ✨ 功能

- 🔍 **跨平台搜索**(七猫 / 番茄),实时结果带封面、评分、字数、人气
- 🏆 **排行榜**
  - **番茄**:官网式导航 —— 综合热榜 / 男频 / 女频,阅读榜·新书榜切换 + 分类标签(东方仙侠、都市…)
  - **七猫**:男生 / 女生 × 大热榜 · 新书榜 · 完结榜 · 收藏榜 · 更新榜
  - 榜单结果缓存 60 秒,重复切换秒开
- 📖 **书籍详情**:作者、简介、章数、评分、字数、热度、榜单、分类、主角
- ⬇️ **一键下载**:TXT / EPUB,实时进度(章数百分比)
- 📂 **已下载管理**:列表 + 删除(仅移除记录 / 同时删除文件)+ Finder 定位
- ⚙️ **设置**:下载目录、保存格式(TXT/EPUB)
- 📐 固定窗口(1100×780,不可拉伸),明暗双模式跟随系统

## 🏗 项目结构

```
novel-downloader-wails/
├── main.go            # Wails 入口(固定窗口 1100×780)
├── app.go             # 绑定层:搜索 / 详情 / 榜单 / 下载 / 设置 / 环境
├── app_test.go        # headless 端到端测试(go test,会真连各平台 API)
├── qimao/             # 七猫下载器(签名 API + AES 解密 + 官网榜单接口)
├── fanqie/            # 番茄下载器(管理 Rust 内核服务 + 官网榜单解析)
├── frontend/          # Vite + 原生 JS 前端(Apple 风格)
│   ├── index.html
│   └── src/main.js, style.css
├── scripts/build.sh   # 构建脚本(打包番茄内核)
└── build/             # 构建产物(build/bin/NovelDownloader.app)
```

## 🔨 构建

前置:Go 1.25+、[Wails CLI](https://wails.io/docs/gettingstarted/installation)、Node.js。
番茄内核置于 `~/bin/Tomato-Novel-Downloader`(或设置 `TOMATO_BIN` 环境变量)。

```bash
cd novel-downloader-wails
./scripts/build.sh
```

产物:`build/bin/NovelDownloader.app`(约 17 MB,自包含番茄内核)。

## 🧪 开发 / 测试

```bash
wails dev      # 热重载开发模式
go test -run TestE2E -v   # 无 GUI 的逻辑链路测试(会真连七猫/番茄 API)
```

## 📦 分发给他人

1. 打包 `NovelDownloader.app`(macOS arm64)。
2. 因仅自签名,首次打开需右键 →「打开」,或执行 `xattr -cr NovelDownloader.app`。
3. 若要完全规避提示,需要 Apple 开发者账号做签名 + 公证(notarytool)。

> 内置番茄内核为 arm64;分发到 Intel Mac 需用 `GOARCH=amd64` 重新构建内核并打包。

## 🗄 数据目录

- 设置:`~/Library/Application Support/novel-downloader/settings.json`
- 下载记录:`~/Library/Application Support/novel-downloader/downloads.json`
- 番茄服务配置:`~/Library/Caches/tomato-novel-downloader/config.yml`
- 默认下载目录:`~/Downloads/NovelDownloader`

## 🔧 技术备注

- **七猫 API**:MD5 签名(`sign`)+ Dart hashCode 模拟 + AES-128-CBC 解密,均为 Go 原生实现;
  榜单走官网 web 接口 `www.qimao.com/qimaoapi/api/rank/book-list`(无需签名,参数 `is_girl` + `rank_type`)。
- **番茄 API**:通过 Rust 服务 `127.0.0.1:18423` 的 REST 接口;榜单抓官网 `/rank` 页(分类导航),
  因官网书名被自定义字体混淆(PUA 私用区字符),榜单需经内核解码书名,已做并发 + 缓存优化。
- **关键坑**:`http.Client{Timeout: 60}` 是 **60 纳秒**而非 60 秒,必须写 `60 * time.Second`。

## 🙏 致谢

本项目在开发过程中参考 / 复用了以下开源项目,在此致以诚挚感谢:

- [**shing-yu/swiftcat-downloader-flutter**](https://github.com/shing-yu/swiftcat-downloader-flutter.git) —— 七猫小说下载器(swiftcat),本项目的七猫 API 签名、AES 解密及下载逻辑移植自其思路。
- [**zhongbai2333/Tomato-Novel-Downloader**](https://github.com/zhongbai2333/Tomato-Novel-Downloader.git) —— 番茄小说下载内核(Rust),本项目番茄平台的搜索 / 下载 / 详情由该内核的本地 REST 服务驱动。
