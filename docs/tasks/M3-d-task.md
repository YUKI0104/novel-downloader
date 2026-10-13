# M3-d 任务书 — Safari 登录态来源 + 使用教程引导

用户拍板：**Q1＝乙**（加 Safari 支持，不装 Chrome）。他的原话：
「短剧模式默认关闭，需要用的时候再打开然后给教程引导用户去登陆获取浏览器登陆态。」

本机现状：**只装了 Safari**（Chrome/Edge/Brave/Vivaldi/Opera 都不存在），Safari 的 cookie 库是
`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`（118KB，今天仍在写）。
注意：这个路径受 macOS 隐私保护（TCC），**我们直接读会被 `Operation not permitted` 挡掉**，只有拿到「完全磁盘访问权限」的 app 才能读——这正是本任务的授权环节。

## 1. Safari cookie 读取器（新）
新增 `ShortdramaSession` 的一个来源：Safari（与现有 Chromium 系并列，**Safari 优先尝试**）。

格式（Safari binarycookies）——照这个实现，别猜：
- 文件头：`"cook"`(4B) + 页数 `uint32 **大端**` + 每页大小数组 `uint32 **大端**`。
- 每页：页头 `uint32 **小端**`（值 0x00000100）+ 本页 cookie 数 `uint32 **小端**`。
  **坑：文件头是大端，页内是小端**（已知实现 SafariCookieJar / browser_cookie3 的 safari 分支就是这么读的，可对照）。
- 每条 cookie 记录：`size`(LE) + `unknown` + `flags` + `has_port` + `domain_offset` + `name_offset` + `path_offset` + `value_offset`（各 uint32 LE）+ `expiry`(double, **Mac 绝对时间＝自 2001-01-01 的秒**) + `creation`(double) + `comment_offset`；之后是各字符串（NUL 结尾，按偏移取）。
- **value 是明文**（Safari cookie 不加密）→ **不需要钥匙串**，也不需要 PBKDF2/AES。
- 取 host 含 `shortdramas.com`（含前导点）且 `name == "sessionid"` 的那条；`expiry == 0` ＝ 会话级不过期；已过期要跳过并报「已过期」。
- 多页要全部扫；找不到条目 → 报「Safari 里没有 shortdramas 登录态」。

## 2. 权限（TCC）处理——必须分清三种情况
1. **文件不存在** → 「Safari 未安装或从未使用过」。
2. **读取被拒（EPERM / `Operation not permitted` / TCC）** → **不要**说成"没有登录态"：文案＝「需要给「番茄猫」开启完全磁盘访问权限才能读取 Safari 登录态」，并给一个按钮直接打开对应的系统设置面板：
   URL scheme：`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`（用 `NSWorkspace.shared.open`）。
   引导里补一句：授权后如果仍读不到，**退出软件重新打开**再试（TCC 有时要重启进程）。
3. **能读但没那条 cookie** → 「未检测到 shortdramas 登录态：请在 Safari 登录 www.shortdramas.com 后重试」。

## 3. 使用教程引导（用户明确要的）
在**他主动打开短剧模式开关时**（以及点「检测登录态」失败时）给出教程，编号步骤、中文、用现有 `FMModalPanel`/`FMButton` 组件：
1. 在 **Safari** 里打开 `www.shortdramas.com` 并登录；
2. 回到「番茄猫」，点设置页的「检测登录态」；
3. 如果提示权限不足：点「打开系统设置」，在**隐私与安全性 → 完全磁盘访问权限**里打开「番茄猫」，然后回软件重试（必要时退出软件重开）；
4. 检测通过后：番茄搜索/榜单里命中的书会带红框和「短剧」角标，番茄详情里会显示 IP 数据条。
教程里不要出现 Chrome/Edge/Brave/Vivaldi/Opera 这套列表当主角——本机只有 Safari；可以在一行小字里提"（也支持 Chrome/Edge 等 Chromium 浏览器）"。

## 4. 文案统一改
所有提到浏览器的地方（首启询问弹窗、详情提示条、设置页灰字、错误文案）改成 **Safari 优先**的表述，与上面第 2、3 节一致；不再把 Chromium 系列在前面。

## 5. 顺手修掉一处不一致
设置页那个开关的显示状态必须**等于实际是否启用**（＝`!ignored && prompted`）。现在若 `prompted=false` 而 `ignored=false`，开关看起来是"开"的但其实没启用——用户会以为坏了。开关显示与 `isEnabled` 一致，用户拨动开关时按 `setIgnored` 语义落库（拨到「开」＝问到过/他同意）。

## 6. 交回
1. 三种情况的实跑证据（贴 `FQM_SELFTEST` 行/日志）：① 文件不存在（可临时改路径模拟）；② 被 TCC 拒（真机现在多半就是这样，如实贴错误与文案）；③ 能读但没有 shortdramas cookie（如果 Safari 库里有别的 cookie 就能验证解析器真的读出来了——**把解析出的 cookie 条数、host 样本（脱敏）贴出来**，证明 parser 不是空转）。
2. 教程引导 + 「打开系统设置」按钮的截图（点击后系统设置面板真的打开，贴 `open` 的结果）。
3. 开关状态 vs `isEnabled` 一致性：`prompted=false` 时开关显示为关的截图。
4. 回归：`chain` 绿；短剧关闭时搜索/榜单/详情与现在完全一致；窗口/卡片/弹窗数值未变。
5. 真机登录态的命中链路由我在用户在机器前时验收（他要给番茄猫开完全磁盘访问权限并登录 Safari）。

## 7. 纪律
先 `ps aux | grep FanQieMao` 看实例，只跑必要轮次，跑完 `bash Tools/跑.sh` 留在普通启动状态；把 settings 还原成 `shortdramaIgnored=true`、`prompted=true`（他的原值）、平台＝番茄。
