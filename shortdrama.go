package main

// 短剧后台信息搜索:读 Edge 登录态 + 调 shortdramas 创作者中心 ip/list 接口。
// 参考: www.shortdramas.com/page/ip-application(需登录)

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/pbkdf2"

	"novel-downloader/qimao"
)

// keychainErrMarker 钥匙串 ACL 拦截错误标记。前端据此弹出引导授权界面
// (输入开机密码 → 一键把 security 工具加入授权列表),而不是只显示错误文字。
const keychainErrMarker = "KEYCHAIN_NEEDS_FIX"

// keychainHint 钥匙串访问失败(系统弹窗未授权)时的可操作提示。
// 一劳永逸:把 security 命令行工具加入条目的分区列表,之后不再弹窗。
const keychainHint = "请在 macOS 弹窗里点「总是允许」,或在引导界面点「一键授权」"

// keychainErr 把钥匙串 ACL 问题包装成带标记的错误,供前端识别。
func keychainErr(err error) error {
	return errors.New(keychainErrMarker + ": " + err.Error() + "。" + keychainHint)
}

// isKeychainAccessIssue 判断该 security 错误是否属于"弹窗未授权"这类可修复问题
// (区别于"该浏览器从未用过、钥匙串里根本没有这个条目")。
func isKeychainAccessIssue(err error) bool {
	s := err.Error()
	return strings.Contains(s, keychainErrMarker) ||
		strings.Contains(s, "User canceled") ||
		strings.Contains(s, "denied") ||
		strings.Contains(s, "超时")
}

// runCmd 带超时执行命令。钥匙串授权弹窗若一直未获批准,避免应用无限阻塞。
func runCmd(timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, errors.New("钥匙串授权超时(卡在系统弹窗)")
	}
	return out, err
}

// FixKeychainAccess 一键授权:把 security 工具加入 login 钥匙串的分区列表,
// 之后读取浏览器密钥不再弹窗。password 为 macOS 开机密码,仅用于本次命令,不保存。
func (a *App) FixKeychainAccess(password string) (string, error) {
	if password == "" {
		return "", errors.New("请输入 Mac 开机密码")
	}
	out, err := runCmd(30*time.Second, "security", "set-key-partition-list",
		"-S", "apple-tool:,apple:", "-k", password, "login")
	if err != nil {
		return "", fmt.Errorf("授权失败(请确认开机密码正确): %v", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// KeychainFixStatus 钥匙串授权状态,供前端决定是否弹出引导授权界面。
type KeychainFixStatus struct {
	OK               bool   `json:"ok"`               // 能正常读取浏览器密钥
	KeychainNeedsFix bool   `json:"keychainNeedsFix"` // 被钥匙串 ACL 拦截,需要引导修复
	Message          string `json:"message"`
}

// ShortdramaSessionStatusEx 检查短剧登录态,返回钥匙串状态。
// 不只是看本地有没有 sessionid cookie,还会用试探词调一次服务端接口确认会话有效。
// 刚在浏览器登录时 Chromium 可能还没把新 cookie 落盘(sqlite 里还是旧值),
// 因此失败后带延迟重试并重新读 cookie,给浏览器落盘时间。
func (a *App) ShortdramaSessionStatusEx() KeychainFixStatus {
	sids, err := shortdramaSessionCandidates()
	if err != nil {
		return KeychainFixStatus{
			KeychainNeedsFix: strings.Contains(err.Error(), keychainErrMarker),
			Message:          err.Error(),
		}
	}
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		for _, sid := range sids {
			if _, err := shortdramaSearchWithSession(sid, "斗破"); err == nil {
				appLog("短剧登录态校验成功(候选 %d 个, 第 %d 轮)", len(sids), attempt+1)
				return KeychainFixStatus{OK: true}
			} else {
				lastErr = err
			}
		}
		if attempt < 2 {
			time.Sleep(1500 * time.Millisecond) // 等 Chromium 落盘新 cookie
			if sids, err = shortdramaSessionCandidates(); err != nil {
				return KeychainFixStatus{
					KeychainNeedsFix: strings.Contains(err.Error(), keychainErrMarker),
					Message:          err.Error(),
				}
			}
		}
	}
	appLog("短剧登录态校验失败: %v", lastErr)
	return KeychainFixStatus{OK: false, Message: "无法访问短剧后台:" + lastErr.Error()}
}

// ShortdramaIP 短剧后台 IP 搜索结果。
type ShortdramaIP struct {
	IPBookID     string `json:"ipBookId"`
	Name         string `json:"name"`
	Author       string `json:"author"`
	Score        string `json:"score"`
	Desc         string `json:"desc"`
	CoverURL     string `json:"coverUrl"`
	Words        string `json:"words"`
	Gender       string `json:"gender"`
	AdaptType    string `json:"adaptType"`
	SelectedCnt  string `json:"selectedCnt"`  // 申请人数/IP 被挑选次数
	AdaptingCnt  string `json:"adaptingCnt"`  // 同 IP 改编中项目数
	ReadingCnt   string `json:"readingCnt"`   // 人在读
	OnlineMonth  string `json:"onlineMonth"`  // 上架时间(首月)
}

// browserSpec 浏览器登录态来源(keychain 密钥服务名 + cookie 库路径)。
// Chromium 系浏览器(Chrome/Edge/Brave/Vivaldi/Opera)加密格式一致。
type browserSpec struct {
	name       string
	keyService string
	cookiePath string
}

var browserSpecs = []browserSpec{
	{"Chrome", "Chrome Safe Storage", "~/Library/Application Support/Google/Chrome/Default/Cookies"},
	{"Edge", "Microsoft Edge Safe Storage", "~/Library/Application Support/Microsoft Edge/Default/Cookies"},
	{"Brave", "Brave Safe Storage", "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"},
	{"Vivaldi", "Vivaldi Safe Storage", "~/Library/Application Support/Vivaldi/Default/Cookies"},
	{"Opera", "Opera Safe Storage", "~/Library/Application Support/com.operasoftware.Opera/Default/Cookies"},
}

// shortdramaSessionID 依次尝试各 Chromium 浏览器,取 .shortdramas.com 的 sessionid。
// 算法与 browser_cookie3 一致:keychain 密钥 → PBKDF2(saltysalt,1003)
// → AES-128-CBC(iv=16空格) → 库版本>=24 时去掉前 32 字节完整性前缀。
// shortdramaSessionID 取第一个可用的浏览器 sessionid(不校验服务端,供旧接口用)。
func shortdramaSessionID() (string, error) {
	sids, err := shortdramaSessionCandidates()
	if err != nil {
		return "", err
	}
	return sids[0], nil
}

// shortdramaSessionCandidates 返回各浏览器里的 sessionid 候选(按浏览器顺序,已过滤过期)。
func shortdramaSessionCandidates() ([]string, error) {
	var sids []string
	var kcErr error
	for _, b := range browserSpecs {
		sid, err := sessionFromBrowser(b)
		if err == nil && sid != "" {
			sids = append(sids, sid)
		} else if err != nil && strings.Contains(err.Error(), keychainErrMarker) && kcErr == nil {
			kcErr = err // 记录钥匙串问题,优先提示它而不是笼统的"未登录"
		}
	}
	if len(sids) == 0 {
		if kcErr != nil {
			return nil, kcErr
		}
		return nil, errors.New("未检测到 shortdramas 登录态:请在 Chrome / Edge / Brave / Vivaldi / Opera 浏览器中登录 www.shortdramas.com 后重试")
	}
	return sids, nil
}

func sessionFromBrowser(b browserSpec) (string, error) {
	home := os.Getenv("HOME")
	key, err := runCmd(20*time.Second, "security", "-q", "find-generic-password", "-w", "-s", b.keyService)
	if err != nil {
		if isKeychainAccessIssue(err) {
			return "", keychainErr(err) // 弹窗未授权/超时:前端弹引导界面
		}
		return "", fmt.Errorf("%s 未安装或从未使用过", b.name)
	}
	dk := pbkdf2.Key(bytes.TrimSpace(key), []byte("saltysalt"), 1003, 16, sha1.New)

	db := expandHome(home, b.cookiePath)
	needStrip := false
	if v, err := exec.Command("sqlite3", db, "SELECT value FROM meta WHERE key='version'").Output(); err == nil {
		if n, convErr := strconv.Atoi(strings.TrimSpace(string(v))); convErr == nil && n >= 24 {
			needStrip = true
		}
	}
	hexVal, err := exec.Command("sqlite3", db,
		"SELECT hex(encrypted_value), expires_utc FROM cookies WHERE host_key='.shortdramas.com' AND name='sessionid' LIMIT 1").Output()
	if err != nil {
		return "", fmt.Errorf("%s 无该 cookie", b.name)
	}
	cols := strings.SplitN(strings.TrimSpace(string(hexVal)), "|", 2)
	expires := int64(0)
	if len(cols) == 2 {
		expires, _ = strconv.ParseInt(strings.TrimSpace(cols[1]), 10, 64)
	}
	if cookieExpired(expires) {
		return "", fmt.Errorf("%s 的登录会话已过期", b.name)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(cols[0]))
	if err != nil {
		return "", err
	}
	if len(raw) < 3 || string(raw[:3]) != "v10" {
		return "", errors.New("cookie 格式不支持")
	}
	block, err := aes.NewCipher(dk)
	if err != nil {
		return "", err
	}
	iv := bytes.Repeat([]byte(" "), 16)
	plain := make([]byte, len(raw)-3)
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, raw[3:])
	// PKCS7 去填充
	if n := len(plain); n > 0 {
		pad := int(plain[n-1])
		if pad >= 1 && pad <= 16 && pad <= n {
			plain = plain[:n-pad]
		}
	}
	if needStrip && len(plain) >= 32 {
		plain = plain[32:]
	}
	return string(plain), nil
}

func expandHome(home, p string) string {
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

// cookieExpired 判断 Chromium cookie 过期时间戳(微秒,自 1601-01-01)是否已过期。
// 0 表示会话级 cookie(无过期时间,浏览器关闭才清)。
func cookieExpired(expiresUTC int64) bool {
	if expiresUTC <= 0 {
		return false
	}
	return time.Now().After(time.Unix(expiresUTC/1_000_000-11644473600, 0))
}

// ShortdramaSearch 按书名搜索短剧后台的 IP(前20条)。
// 依次尝试各浏览器的 sessionid,失效的自动跳过(多浏览器时不受某个残留旧会话影响)。
func (a *App) ShortdramaSearch(keyword string) ([]ShortdramaIP, error) {
	sids, err := shortdramaSessionCandidates()
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, sid := range sids {
		out, err := shortdramaSearchWithSession(sid, keyword)
		if err == nil {
			return out, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

// shortdramaSearchWithSession 用指定 session 调短剧后台接口。
func shortdramaSearchWithSession(sid, keyword string) ([]ShortdramaIP, error) {
	u := "https://www.shortdramas.com/api/origin/cp/playlet/ip/list/v:version" +
		"?page_no=1&page_count=20&image_fmt=180x240&op_channel=1&ip_adaptation_type=2&aid=791322" +
		"&book_name=" + url.QueryEscape(keyword)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	req.Header.Set("Referer", "https://www.shortdramas.com/page/ip-application")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Cookie", "sessionid="+sid)
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("短剧后台 HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    struct {
			IPList []map[string]interface{} `json:"ip_list"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Code != 0 {
		msg := payload.Message
		if msg == "" {
			msg = "未知错误"
		}
		return nil, fmt.Errorf("短剧后台返回错误 code=%d: %s", payload.Code, msg)
	}
	out := make([]ShortdramaIP, 0, len(payload.Data.IPList))
	for _, it := range payload.Data.IPList {
		out = append(out, ShortdramaIP{
			IPBookID: strconv.FormatInt(int64(intOf(it["ip_book_id"])), 10),
			Name:     strOf(it["ip_name"]),
			Author:   strOf(it["author_name"]),
			Score:    strOf(it["book_score"]),
			Desc:     strOf(it["book_desc"]),
			CoverURL: strOf(it["thumb_url"]),
			Words:       qimao.FormatWords(intOf(it["word_num"])),
			Gender:      ipGenderLabel(intOf(it["gender"])),
			AdaptType:   strconv.Itoa(intOf(it["ip_adaptation_type"])),
			SelectedCnt: strconv.Itoa(intOf(it["ip_selected_count"])),
			AdaptingCnt: strconv.Itoa(intOf(it["same_ip_adapting_count"])),
			ReadingCnt:  strconv.Itoa(intOf(it["read_listen_dcnt_14d"])),
			OnlineMonth: strOf(it["first_online_month"]),
		})
	}
	return out, nil
}

func ipGenderLabel(g int) string {
	switch g {
	case 1:
		return "男频"
	case 2:
		return "女频"
	default:
		return ""
	}
}

func strOf(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", t)
	}
}

func intOf(v interface{}) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(t)
		return n
	case nil:
		return 0
	default:
		return 0
	}
}
