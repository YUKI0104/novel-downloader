# M3-a 任务书 — 短剧 IP 数据层照搬（不接界面联动）

M3 分两半，这一半**不需要钥匙串授权、不接界面**，只把旧版短剧逻辑逐函数照搬成 Swift 并做数据层自检；界面联动（命中高亮/角标/数量、番茄详情 IP 数据条、短剧模式开关的界面联动）留到 M3-b，届时用户在机器前配合授权。

## 1. 参照源（只读，别改；逐函数对照移植）
`~/code/novel-downloader/shortdrama.go`（375 行）：
- 钥匙串/会话：`keychainErr`(:39) / `isKeychainAccessIssue`(:45) / `runCmd`(:54) / `FixKeychainAccess`(:67) / `ShortdramaSessionStatusEx`(:90)
- 会话取cookie：`shortdramaSessionID`(:159) / `shortdramaSessionCandidates`(:168) / `sessionFromBrowser`(:188) / `expandHome`(:246) / `cookieExpired`(:255)
  （Chromium 系浏览器的 cookie 库解密：AES + PBKDF2，需读钥匙串里的 safe storage 密钥——**照搬实现，不要另起炉灶**）
- 查询：`ShortdramaSearch`(:264) / `shortdramaSearchWithSession`(:281)
- 工具：`ipGenderLabel`(:339) / `strOf`(:350) / `intOf`(:363)
前端调用点（用来定数据层接口形状，别改前端）：`frontend/src/main.js` 的 `:166-180`（短剧模式开关 + 平台切换联动）、`:319-323`、`:378-382`、`:424-467`、`:538-578`、`:719`。
设置项参照：旧版 `shortdramaIgnored`（前端 `:992`、`:1024-1033`）。

## 2. 要做的
1. `Sources/Core/Shortdrama/`：把上面函数逐条照搬成 Swift（含 cookie 解密、会话探测、搜索、性别标签、工具函数），命名与职责对齐 Go 版本，便于以后对照。
2. 设置项：`shortdramaIgnored`（沿用旧 settings.json 的键与语义——**别改数据格式**，老用户的设置要能读出来）。
3. 自检钩子（`FQM_SELFTEST`）：
   - `sd-session`：打印会话状态（有没有找到候选、用的是哪个浏览器、cookie 是否过期、失败原因一句话），**不许**在没有登录态时挂住——失败要明确报出；
   - `sd-search <关键词>`：命中时打印前若干条 IP（书名/性别标签/ID），未命中/无会话要区分开。
4. 明确不做（M3-b 再做）：搜索/榜单的命中高亮与角标、状态行「N 本在短剧后台」、番茄详情 IP 数据条、设置页那个开关的界面、失败时的登录提示弹层。

## 3. 交回
1. 文件清单 + 每个函数对应的 Go 行号（一一对上，缺哪个说明为什么）。
2. `sd-session` 实跑输出（有/无登录态两种情况的真实输出；没登录态就如实报"未找到会话"）。
3. `sd-search` 在**没有浏览器登录态**时的行为（必须明确报错、不挂住、不崩）。
4. 说明：读钥匙串这一步在你的实现里什么时候触发（应当只在真正需要密钥时触发，不能一启动就弹授权）。
5. 回归：`chain` 绿；窗口/卡片/弹窗数值未变。

## 4. 纪律
- 用户可能正开着 app（现在默认就是番茄界面、七猫已开放）。跑自检前先 `ps aux | grep FanQieMao` 看实例，只跑必要轮次，跑完把 app 留在**普通启动**状态。
- 禁止改：番茄/七猫协议与签名、内核行为、已验证的布局数值、文案口径。
