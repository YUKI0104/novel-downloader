package fanqie

// Chromium 系浏览器(Chrome/Edge/Brave/Vivaldi/Opera)的 cookie 解密读取。
// 与主包 shortdrama.go 的登录态读取同款算法:keychain 密钥 → PBKDF2(saltysalt,1003)
// → AES-128-CBC(iv=16 空格) → 库版本>=24 时去掉前 32 字节完整性前缀。
// 用于把用户浏览器里访问过 fanqienovel.com 后种下的 ttwid 等 cookie 注入榜单请求,
// 帮助绕过 fanqie 对非浏览器客户端的反爬拦截(HTTP 444)。

import (
	"bytes"
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
	key, err := exec.Command("security", "-q", "find-generic-password", "-w", "-s", b.keyService).Output()
	if err != nil {
		return nil, fmt.Errorf("读取 %s 密钥失败", b.name)
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
		"SELECT name, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%"+hostSubstring+"%'").Output()
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(rows)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		if len(parts) != 2 {
			continue
		}
		val, err := decryptCookieValue(strings.TrimSpace(parts[1]), dk, needStrip)
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
