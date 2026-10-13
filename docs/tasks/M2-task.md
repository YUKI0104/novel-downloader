# M2 任务书 — 七猫（搜索/详情/下载/榜单/改编书单）+ EPUB 导出

> 状态：**已开工**（2026-10-09 用户回「可以了！」＝界面通过，开 M2）。
> 规格来源：`docs/spec-v0.1.md` 第 1 节「阶段 M2」。

## 分批（Hermes 定，为了不干扰正在跑的界面迭代）
- **M2-a（先做，不动任何界面文件）**：`Core/Qimao/**` 客户端全量（签名/请求头/搜索/详情/章节列表/榜单/改编书单/下载 URL+ZIP/解密/解压）+ TXT/EPUB 写出 + 自检钩子。交回标准＝数据对照 + 真文件（TXT/EPUB）。
- **M2-b（M2-a 通过后）**：界面接入（顶栏平台切换、七猫榜单/搜索/详情/下载/改编书单 UI），**全部跑通并通过验收前不向用户暴露七猫入口**。

## 0. 交付总目标
把旧版 Go 的七猫链路**逐文件照搬**成 Swift，并在顶栏开放平台切换（番茄 | 七猫）；EPUB 导出沿用现有中文 EPUB 2.0 结构。

## 1. 参照源（只读，别改；逐个函数对照移植）
`~/code/novel-downloader/qimao/qimao.go`（777 行）：
- `sign`(:54) / `stableHash`(:72) — **七猫签名算法，禁改**（照抄）
- `requestHeaders`(:83) / `ExtractBookID`(:117) / `isAllDigits`(:133) / `SafeFilename`(:146) / `stripHTML`(:156)
- `NewClient`(:255) / `get`(:259) — 请求底座（baseKey/path/params/bookID）
- `Search`(:288) / `BookDetail`(:325) / `ChapterList`(:368) / `RankingBooks`(:398)
- `adaptFetch`(:463) / `AdaptRankConfig`(:487) / `AdaptBookList`(:509) — 改编书单
- `DownloadURL`(:567) / `DownloadZip`(:584) / `Decrypt`(:602) / `UnzipChapters`(:632) / `Download`(:659)
- 工具：`wordsText`(:559) / `strOf`(:707) / `intOf`(:720) / `firstNonEmpty`(:734)
`~/code/novel-downloader/qimao/writers.go`（295 行）：EPUB 写出（中文 EPUB 2.0 结构）与 TXT 写出。
前端参照：`frontend/index.html` 59–62 行（平台下拉）、`frontend/src/main.js` 里七猫分支（`QimaoRankBooks` / `QimaoAdaptConfig` / `QimaoAdaptBooks` 调用点）。

## 2. 要做的
1. **Core/Qimao/**：照搬上面全部函数（签名/请求/搜索/详情/章节/榜单/改编书单/下载/解密/解压），不重新设计协议。
2. **下载**：七猫 TXT 与 EPUB 两种格式（设置页「保存格式」已存在；文件名规则与旧版一致 `书名 作者 [ID].txt`）。
3. **顶栏平台切换**：番茄 | 七猫（旧版是下拉，新版沿用现有胶囊样式；**七猫这一侧在搜索/详情/下载/榜单全部跑通并通过验收前，不要向用户暴露半成品入口**——开发期用环境变量或隐藏开关）。
4. **榜单**：七猫榜单（`RankingBooks(isGirl, rankType)`）+ 番茄已有的频道行按平台切换参数。
5. **改编书单**：筛选组（改编方向/所属频道/作品分类/作品字数/是否完结/热门书单）+ 分页（旧版 `.adapt-filters` + `.adapt-pager` 上一页/下一页）。**短剧 IP 数据条属 M3，不做。**
6. **EPUB 导出**：先做七猫侧的 EPUB（走 writers.go 的结构），番茄侧 EPUB 若旧版也支持则一并接。

## 3. 禁止
- 禁止改七猫签名算法、请求头、接口协议、URL 结构。
- 禁止动已验证的 M1 部分：番茄搜索/详情/下载/榜单、三个弹窗与其关闭路径、布局数值（18/12/210/34/16）、窗口玻璃、内核与自动更新、文案口径（用户可见文案一律中文）。
- 禁止自创界面；七猫的 UI 形态与番茄同一套组件（AlbumCard/ResultsArea/Modal）。

## 4. 验收（交给我）
1. 七猫搜索（书名/ID/链接）出真结果 + 与 qimao 官网前几条对照；详情（章节数/简介/评分）；下载 TXT 与 EPUB 各出一份真文件（贴文件大小、前 200 字节、EPUB 用 `unzip -l` 列出结构）。
2. 七猫榜单（男/女 + 各榜单类型）截图 + 数据对照。
3. 改编书单：筛选组展示 + 换筛选重取 + 上一页/下一页 + 数据对照。
4. 平台切换：番茄 ↔ 七猫 来回切 3 次，各自的榜单/搜索/详情/下载都正常（贴日志）。
5. 计时：七猫搜索/详情/下载、榜单首次与命中缓存。
6. 回归：M1 的 chain 自检、closepaths2 矩阵、更新链 mock 三例全部仍绿。
