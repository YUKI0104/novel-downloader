package fanqie

// Chromium 系浏览器(Chrome/Edge/Brave/Vivaldi/Opera)的 cookie 解密读取。
// 与主包 shortdrama.go 的登录态读取同款算法:keychain 密钥 → PBKDF2(saltysalt,1003)
// → AES-128-CBC(iv=16 空格) → 库版本>=24 时去掉前 32 字节完整性前缀。
// 用于把用户浏览器里访问过 fanqienovel.com 后种下的 ttwid 等 cookie 注入榜单请求,
// 帮助绕过 fanqie 对非浏览器客户端的反爬拦截(HTTP 444)。

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/pbkdf2"
)

type cookieSpec struct {
	name       string
	keyService string
	cookiePath string
}

var cookieBrowsers = []cookieSpec{
	{"Chrome", "Chrome Safe Storage", "~/Library/Application Support/Google/Chrome/Default/Cookies"},
	{"Edge", "Microsoft Edge Safe Storage", "~/Library/Application Support/Microsoft Edge/Default/Cookies"},
	{"Brave", "Brave Safe Storage", "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"},
	{"Vivaldi", "Vivaldi Safe Storage", "~/Library/Application Support/Vivaldi/Default/Cookies"},
	{"Opera", "Opera Safe Storage", "~/Library/Application Support/com.operasoftware.Opera/Default/Cookies"},
}

// keychainErrMarker 钥匙串 ACL 拦截错误标记,前端据此弹出引导授权界面。
const keychainErrMarker = "KEYCHAIN_NEEDS_FIX"

// keychainAccessErr 钥匙串 ACL 拦截错误(带 KEYCHAIN_NEEDS_FIX 标记,前端弹引导界面)。
func keychainAccessErr(msg string) error {
	return errors.New(keychainErrMarker + ": " + msg + "。请在引导界面点「一键授权」")
}

// browserCookies 从任一 Chromium 浏览器读取 host_key 包含 hostSubstring 的所有 cookie。
func browserCookies(hostSubstring string) (map[string]string, error) {
	for _, b := range cookieBrowsers {
		if m, err := cookiesFromBrowser(b, hostSubstring); err == nil && len(m) > 0 {
			return m, nil
		}
	}
	return nil, errors.New("未在浏览器中找到该站点的 cookie")
}

func cookiesFromBrowser(b cookieSpec, hostSubstring string) (map[string]string, error) {
	home := os.Getenv("HOME")
	// 钥匙串授权弹窗可能一直卡住,带超时避免应用无限阻塞。
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	key, err := exec.CommandContext(ctx, "security", "-q", "find-generic-password", "-w", "-s", b.keyService).Output()
	cancel()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, keychainAccessErr("钥匙串授权超时(卡在系统弹窗)")
	}
	if err != nil {
		return nil, keychainAccessErr(fmt.Sprintf("读取 %s 钥匙串失败: %v", b.name, err))
	}
	dk := pbkdf2.Key(bytes.TrimSpace(key), []byte("saltysalt"), 1003, 16, sha1.New)

	db := filepath.Join(home, strings.TrimPrefix(b.cookiePath, "~/"))
	needStrip := false
	if v, err := exec.Command("sqlite3", db, "SELECT value FROM meta WHERE key='version'").Output(); err == nil {
		if n, convErr := strconv.Atoi(strings.TrimSpace(string(v))); convErr == nil && n >= 24 {
			needStrip = true
		}
	}
	rows, err := exec.Command("sqlite3", db,
		"SELECT name, expires_utc, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%"+hostSubstring+"%'").Output()
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(rows)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		if len(parts) != 3 {
			continue
		}
		expires, _ := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
		if cookieExpired(expires) {
			continue // 已过期,不算有效 cookie
		}
		val, err := decryptCookieValue(strings.TrimSpace(parts[2]), dk, needStrip)
		if err != nil || val == "" {
			continue
		}
		out[strings.TrimSpace(parts[0])] = val
	}
	if len(out) == 0 {
		return nil, errors.New("无匹配 cookie")
	}
	return out, nil
}

// cookieExpired 判断 Chromium cookie 过期时间戳(微秒,自 1601-01-01)是否已过期。
// 0 表示会话级 cookie(无过期时间)。
func cookieExpired(expiresUTC int64) bool {
	if expiresUTC <= 0 {
		return false
	}
	return time.Now().After(time.Unix(expiresUTC/1_000_000-11644473600, 0))
}

func decryptCookieValue(hexVal string, dk []byte, needStrip bool) (string, error) {
	raw, err := hex.DecodeString(hexVal)
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
