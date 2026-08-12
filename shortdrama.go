package main

// 短剧后台信息搜索:读 Edge 登录态 + 调 shortdramas 创作者中心 ip/list 接口。
// 参考: www.shortdramas.com/page/ip-application(需登录)

import (
	"bytes"
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
func shortdramaSessionID() (string, error) {
	var errs []string
	for _, b := range browserSpecs {
		if sid, err := sessionFromBrowser(b); err == nil && sid != "" {
			return sid, nil
		} else if err != nil {
			errs = append(errs, b.name+": "+err.Error())
		}
	}
	if len(errs) == 0 {
		errs = append(errs, "所有浏览器均未找到会话")
	}
	return "", errors.New(strings.Join(errs, "; "))
}

func sessionFromBrowser(b browserSpec) (string, error) {
	home := os.Getenv("HOME")
	key, err := exec.Command("security", "-q", "find-generic-password", "-w", "-s", b.keyService).Output()
	if err != nil {
		return "", fmt.Errorf("读取 %s 密钥失败", b.name)
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
		"SELECT hex(encrypted_value) FROM cookies WHERE host_key='.shortdramas.com' AND name='sessionid' LIMIT 1").Output()
	if err != nil {
		return "", fmt.Errorf("%s 无该 cookie", b.name)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(hexVal)))
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

// ShortdramaSearch 按书名搜索短剧后台的 IP(前20条)。
func (a *App) ShortdramaSearch(keyword string) ([]ShortdramaIP, error) {
	sid, err := shortdramaSessionID()
	if err != nil {
		return nil, err
	}
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
		Code int `json:"code"`
		Data struct {
			IPList []map[string]interface{} `json:"ip_list"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Code != 0 {
		return nil, fmt.Errorf("短剧后台返回错误 code=%d", payload.Code)
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
