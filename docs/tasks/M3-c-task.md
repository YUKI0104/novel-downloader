# M3-c 任务书（小）— 短剧模式的「首启询问」按旧版补回

M3-b 已验收提交（`4c6021c`）。发现一处与旧版不一致，按旧版修回来：

## 问题
旧版 `frontend/src/main.js:1187` 的 `sdActive = !shortdramaIgnored && shortdramaPrompted`：
**没被问过的用户，短剧功能是不启用的**（首启会问一次要不要启用短剧 IP）。
我们现在的 `ShortdramaStore.isEnabled` 只判 `!shortdramaIgnored`，等于**没问过也会去读浏览器登录态/查后台**。
（用户这台机器上 `shortdramaPrompted=true` 且 `shortdramaIgnored=true`，所以行为没变；新装机器会不一样——不能替用户默认开启。）

## 要做的
1. 判定改回旧版语义：`isEnabled = !shortdramaIgnored && shortdramaPrompted`（用同一个键 `shortdramaPrompted`，格式不变）。
2. 用户**主动在设置页打开**短剧模式开关时，把 `shortdramaPrompted` 置 true（这就是"问过了/他同意"的落点）。
3. 首次使用（`shortdramaPrompted == false`）时的表现沿用旧版口径：不自动读浏览器登录态、不查后台、不显示命中与数据条；按旧版那样给一次「是否启用短剧 IP」的询问（**用现有 Modal/FMButton 组件，不许自创造型**；措辞照旧版，说明"会读取本机浏览器的登录态以查询短剧后台"）。用户拒绝 → `shortdramaIgnored=true`；同意 → 两者都置位并启用。
4. 回归：`chain` 绿；短剧关闭时搜索/榜单/详情与现在完全一致（无角标、无计数、无提示条）。

## 交回
1. 截图：首启询问弹窗 + 拒绝后设置页状态；2. 数字：`shortdramaPrompted=false` 时三条链路均不查后台（读钥匙串次数=0、无网络请求，贴日志）；3. `chain` 绿。
## 纪律
先 `ps aux | grep FanQieMao` 看实例，只跑必要轮次，跑完 `bash Tools/跑.sh` 留在普通启动状态。
