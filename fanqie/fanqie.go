// Package fanqie 番茄小说下载器 —— 从 fanqie.py 忠实移植。
// 通过管理 Tomato-Novel-Downloader (Rust) REST 服务完成搜索/下载。
// 参考: ~/.claude/skills/novel-down/scripts/fanqie.py
package fanqie

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const (
	DefaultPort  = 18423
	baseURLFmt   = "http://127.0.0.1:%d"
	pidFile      = "/tmp/tomato-server.pid"
	pollInterval = time.Second
)

// rankCacheEntry 榜单缓存项(短 TTL,榜单变化不频繁)。
type rankCacheEntry struct {
	books []Book
	at    time.Time
}

// Client 是番茄服务的 REST 客户端 + 服务器管理器。
type Client struct {
	Port    int
	Tomato  string // Rust binary 路径
	DataDir string // 数据目录(config.yml/logs)
	SaveDir string // 下载保存目录(写入 config.yml 的 save_path)

	serverStarted bool
	pid           int

	rankMu    sync.Mutex
	rankCache map[string]rankCacheEntry // URL → 榜单缓存
}

// NewClient 默认配置。tomatoBin 为空则用 ~/bin/Tomato-Novel-Downloader。
func NewClient(tomatoBin, dataDir, saveDir string) *Client {
	if tomatoBin == "" {
		tomatoBin = filepath.Join(os.Getenv("HOME"), "bin", "Tomato-Novel-Downloader")
	}
	if dataDir == "" {
		dataDir = filepath.Join(os.Getenv("HOME"), "Library", "Caches", "tomato-novel-downloader")
	}
	return &Client{Port: DefaultPort, Tomato: tomatoBin, DataDir: dataDir, SaveDir: saveDir, rankCache: map[string]rankCacheEntry{}}
}

func (c *Client) base() string { return fmt.Sprintf(baseURLFmt, c.Port) }

// ---------------------------------------------------------------------------
// 服务器管理
// ---------------------------------------------------------------------------

func (c *Client) isRunning() bool {
	resp, err := (&http.Client{Timeout: 2 * time.Second}).Get(c.base() + "/api/status")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// Status 返回服务器是否在运行。
func (c *Client) Status() bool { return c.isRunning() }

// EnsureServer 确保服务器运行。未运行则写入配置并启动。
func (c *Client) EnsureServer() error {
	if c.isRunning() {
		return nil
	}
	if _, err := os.Stat(c.Tomato); err != nil {
		return fmt.Errorf("未找到 %s，请先安装 Tomato-Novel-Downloader", c.Tomato)
	}
	if err := c.ensureConfig(); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	if err := os.MkdirAll(c.DataDir, 0755); err != nil {
		return err
	}
	cmd := exec.Command(c.Tomato, "--server", "--data-dir", c.DataDir)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动番茄服务失败: %w", err)
	}
	c.serverStarted = true
	c.pid = cmd.Process.Pid
	_ = os.WriteFile(pidFile, []byte(fmt.Sprint(c.pid)), 0644)

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if c.isRunning() {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	cmd.Process.Kill()
	_ = os.Remove(pidFile)
	return errors.New("服务器启动超时")
}

// StopServer 停止服务器(含 PID 文件中记录的旧进程)。
func (c *Client) StopServer() error {
	if c.pid > 0 {
		if p, err := os.FindProcess(c.pid); err == nil {
			p.Kill()
		}
		c.pid = 0
	}
	if b, err := os.ReadFile(pidFile); err == nil {
		var pid int
		if n, _ := fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &pid); n == 1 && pid > 0 {
			if p, err := os.FindProcess(pid); err == nil {
				p.Kill()
			}
		}
	}
	_ = os.Remove(pidFile)
	// 等端口释放
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if !c.isRunning() {
			break
		}
		time.Sleep(300 * time.Millisecond)
	}
	return nil
}

// ensureConfig 确保 config.yml 存在且 save_path / novel_format 正确。
func (c *Client) ensureConfig() error {
	if err := os.MkdirAll(c.DataDir, 0755); err != nil {
		return err
	}
	path := filepath.Join(c.DataDir, "config.yml")
	var content string
	if b, err := os.ReadFile(path); err == nil {
		content = string(b)
	} else {
		// 用默认模板
		content = defaultConfigYAML
	}
	content = setYAMLValue(content, "save_path", c.SaveDir)
	content = setYAMLValue(content, "novel_format", "txt")
	return os.WriteFile(path, []byte(content), 0644)
}

func setYAMLValue(content, key, value string) string {
	re := regexp.MustCompile(`(?m)^(` + key + `:).*$`)
	if re.MatchString(content) {
		return re.ReplaceAllString(content, "${1} "+value)
	}
	return content + "\n" + key + ": " + value + "\n"
}

// defaultConfigYAML 最小的默认配置(Rust 服务会补全其余字段)。
const defaultConfigYAML = `# 是否使用老版本命令行界面
old_cli: false
# 最大并发线程数
max_workers: 3
# 请求超时时间（秒）
request_timeout: 15
# 保存小说格式, 可选: [txt, epub, pdf]
novel_format: txt
# 是否以散装形式保存小说
bulk_files: false
# 下载完成后自动用默认应用打开生成的小说文件/文件夹（txt/epub）
auto_open_downloaded_files: false
# 保存路径
save_path: ''
# 使用官方API
use_official_api: true
# API列表
api_endpoints: []
`

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

func (c *Client) apiGet(path string, params map[string]string) (map[string]interface{}, error) {
	u := c.base() + path
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	if len(params) > 0 {
		q := req.URL.Query()
		for k, v := range params {
			q.Set(k, v)
		}
		req.URL.RawQuery = q.Encode()
	}
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

func (c *Client) apiPost(path string, body map[string]interface{}) (map[string]interface{}, error) {
	buf, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, c.base()+path, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

type Book struct {
	BookID       string
	Title        string
	Author       string
	Category     string
	Description  string
	ChapterCount int
	CoverURL     string
	Words        string // 字数
	Hot          string // 在读
	Score        string // 评分
}

type SearchResult struct {
	BookID   string
	Title    string
	Author   string
	Abstract string
	Score    string // 评分
	Words    string // 字数,如 "536万字"
	Hot      string // 在读人数文案
	CoverURL string // 封面(绝对 URL)
}

type JobStatus struct {
	ID            string
	State         string
	Message       string
	SavedChapters int
	ChapterTotal  int
}

// ---------------------------------------------------------------------------
// 业务接口
// ---------------------------------------------------------------------------

// Search 搜索。
func (c *Client) Search(keyword string) ([]SearchResult, error) {
	data, err := c.apiGet("/api/search", map[string]string{"q": keyword})
	if err != nil {
		return nil, err
	}
	items, _ := data["items"].([]interface{})
	var results []SearchResult
	for _, it := range items {
		m, _ := it.(map[string]interface{})
		bookID := strOf(m["book_id"])
		if bookID == "" {
			continue
		}
		title := strOf(m["title"])
		if title == "" {
			if raw, ok := m["raw"].(map[string]interface{}); ok {
				title = strOf(raw["book_name"])
			}
		}
		var r SearchResult
		r.BookID, r.Title, r.Author = bookID, title, strOf(m["author"])
		if raw, ok := m["raw"].(map[string]interface{}); ok {
			r.Abstract = strOf(raw["abstract"])
			r.Score = strOf(raw["score"])
			r.Hot = strOf(raw["read_count_text"])
			if wn := intOf(raw["word_number"]); wn > 0 {
				r.Words = FormatWords(wn)
			}
			r.CoverURL = strOf(raw["thumb_url"])
		}
		results = append(results, r)
	}
	return results, nil
}

// Preview 书籍详情。
func (c *Client) Preview(bookID string) (*Book, error) {
	data, err := c.apiGet("/api/preview/"+bookID, nil)
	if err != nil {
		return nil, err
	}
	b := &Book{
		BookID:       firstNonEmpty(strOf(data["book_id"]), bookID),
		Title:        strOf(data["book_name"]),
		Author:       strOf(data["author"]),
		Category:     strOf(data["category"]),
		Description:  strOf(data["description"]),
		ChapterCount: intOf(data["chapter_count"]),
		CoverURL:     strOf(data["detail_cover_url"]),
		Hot:          strOf(data["read_count_text"]),
		Score:        strOf(data["score"]),
	}
	if wc := intOf(data["word_count"]); wc > 0 {
		b.Words = FormatWords(wc)
	}
	return b, nil
}

// ResolveCover 把相对封面路径补全为完整 URL(本地番茄服务返回相对路径)。
func (c *Client) ResolveCover(rel string) string {
	if strings.HasPrefix(rel, "/") {
		return c.base() + rel
	}
	return rel
}

// ---------------------------------------------------------------------------
// 排行榜(抓取番茄官网排行页)
// ---------------------------------------------------------------------------

const rankBaseURL = "https://fanqienovel.com"

const fanqieWebUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

// RankGenre 单个类型榜单(阅读榜/新书榜两个 URL)。
type RankGenre struct {
	Name    string
	ReadURL string // 阅读榜 (b=1)
	NewURL  string // 新书榜 (b=2)
}

// RankGroup 榜单分组: 综合 | 男频 | 女频。
type RankGroup struct {
	Gender string
	HotURL string      // 综合热榜 URL(仅综合分组有)
	Genres []RankGenre // 该性别下的类型榜单
}

func fetchHTML(rawURL string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", fanqieWebUA)
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func isObfuscated(s string) bool {
	for _, r := range s {
		if r >= 0xE000 && r <= 0xF8FF {
			return true
		}
	}
	return false
}

// RankCategories 抓取官网排行页,按 综合/男频/女频 分组返回。
// URL 结构: /rank/{性别}_{榜单类型}_{分类} (性别 1=男 0=女; 类型 1=阅读 2=新书)。
func RankCategories() ([]RankGroup, error) {
	htmlStr, err := fetchHTML(rankBaseURL + "/rank")
	if err != nil {
		return nil, err
	}
	byGender := map[string]map[string]*RankGenre{}
	re := regexp.MustCompile(`<a[^>]*href="(/rank/(\d+)_(\d+)_(\d+))"[^>]*>(.*?)</a>`)
	for _, m := range re.FindAllStringSubmatch(htmlStr, -1) {
		genderCode, rankType := m[2], m[3]
		label := strings.TrimSpace(regexp.MustCompile(`<[^>]+>`).ReplaceAllString(m[5], ""))
		label = strings.TrimSpace(strings.ReplaceAll(label, "\n", " "))
		if label == "" || isObfuscated(label) {
			continue
		}
		gender := "男频"
		if genderCode == "0" {
			gender = "女频"
		}
		if byGender[gender] == nil {
			byGender[gender] = map[string]*RankGenre{}
		}
		g := byGender[gender][label]
		if g == nil {
			g = &RankGenre{Name: label}
			byGender[gender][label] = g
		}
		if rankType == "1" {
			g.ReadURL = rankBaseURL + m[1]
		} else {
			g.NewURL = rankBaseURL + m[1]
		}
	}
	groups := []RankGroup{{Gender: "综合", HotURL: rankBaseURL + "/rank"}}
	for _, gender := range []string{"男频", "女频"} {
		gm := byGender[gender]
		if len(gm) == 0 {
			continue
		}
		names := make([]string, 0, len(gm))
		for name := range gm {
			names = append(names, name)
		}
		sort.Strings(names)
		genres := make([]RankGenre, 0, len(names))
		for _, name := range names {
			genres = append(genres, *gm[name])
		}
		groups = append(groups, RankGroup{Gender: gender, Genres: genres})
	}
	return groups, nil
}

// FetchRankBookIDs 抓取榜单页的有序书 ID(去重)。
func FetchRankBookIDs(rankURL string) ([]string, error) {
	htmlStr, err := fetchHTML(rankURL)
	if err != nil {
		return nil, err
	}
	re := regexp.MustCompile(`/page/(\d{15,})`)
	var ids []string
	seen := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(htmlStr, -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			ids = append(ids, m[1])
		}
	}
	return ids, nil
}

// RankingBooks 返回榜单书籍(前10),通过本地内核 preview 补全信息。
// 每次 preview 都要让内核去官网抓书页,串行会很慢(10 本 ≈ 10s):
//  1. 用并发 8 的 worker 池并行补全(保持榜单名次顺序);
//  2. 结果按 URL 缓存 60s,重复切榜单秒开。
func (c *Client) RankingBooks(rankURL string) ([]Book, error) {
	const rankCacheTTL = 60 * time.Second
	c.rankMu.Lock()
	if e, ok := c.rankCache[rankURL]; ok && time.Since(e.at) < rankCacheTTL {
		c.rankMu.Unlock()
		return e.books, nil
	}
	c.rankMu.Unlock()

	ids, err := FetchRankBookIDs(rankURL)
	if err != nil {
		return nil, err
	}
	if len(ids) > 10 {
		ids = ids[:10]
	}
	books := make([]*Book, len(ids))
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for i, id := range ids {
		wg.Add(1)
		go func(i int, id string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if b, err := c.Preview(id); err == nil {
				books[i] = b
			}
		}(i, id)
	}
	wg.Wait()
	out := make([]Book, 0, len(ids))
	for _, b := range books {
		if b != nil {
			out = append(out, *b)
		}
	}
	c.rankMu.Lock()
	c.rankCache[rankURL] = rankCacheEntry{books: out, at: time.Now()}
	c.rankMu.Unlock()
	return out, nil
}

// CreateJob 创建下载任务。start/end 为 0 表示全部。
func (c *Client) CreateJob(bookID string, start, end int) (string, error) {
	body := map[string]interface{}{"book_id": bookID}
	if start > 1 {
		body["range_start"] = start
	}
	if end > 0 {
		body["range_end"] = end
	}
	data, err := c.apiPost("/api/jobs", body)
	if err != nil {
		return "", err
	}
	id := strOf(data["id"])
	if id == "" {
		return "", errors.New("创建任务失败: 无返回ID")
	}
	return id, nil
}

// JobStatus 查询任务状态。
func (c *Client) JobStatus(id string) (*JobStatus, error) {
	data, err := c.apiGet("/api/jobs", map[string]string{"id": id})
	if err != nil {
		return nil, err
	}
	items, _ := data["items"].([]interface{})
	if len(items) == 0 {
		return nil, nil
	}
	m, _ := items[0].(map[string]interface{})
	js := &JobStatus{ID: id, State: strOf(m["state"]), Message: strOf(m["message"])}
	if p, ok := m["progress"].(map[string]interface{}); ok {
		js.SavedChapters = intOf(p["saved_chapters"])
		js.ChapterTotal = intOf(p["chapter_total"])
	}
	return js, nil
}

// Library 列出已下载。
func (c *Client) Library() ([]LibraryItem, error) {
	data, err := c.apiGet("/api/library", nil)
	if err != nil {
		return nil, err
	}
	root := strOf(data["root"])
	items, _ := data["items"].([]interface{})
	var out []LibraryItem
	for _, it := range items {
		if m, ok := it.(map[string]interface{}); ok {
			out = append(out, libraryItemFrom(m))
		}
	}
	_ = root
	return out, nil
}

type LibraryItem struct {
	Name    string
	Path    string
	IsDir   bool
	Size    int64
	Formats []string
}

func libraryItemFrom(m map[string]interface{}) LibraryItem {
	it := LibraryItem{
		Name:  strOf(m["name"]),
		Path:  strOf(m["path"]),
		IsDir: boolOf(m["is_dir"]),
		Size:  int64(intOf(m["size"])),
	}
	if it.IsDir {
		if children, ok := m["children"].([]interface{}); ok {
			seen := map[string]bool{}
			for _, ch := range children {
				if cm, ok := ch.(map[string]interface{}); ok {
					ext := filepath.Ext(strOf(cm["name"]))
					if ext != "" && !seen[ext] {
						seen[ext] = true
						it.Formats = append(it.Formats, strings.TrimPrefix(ext, "."))
					}
				}
			}
		}
	}
	return it
}

// ---------------------------------------------------------------------------
// 下载 + 文件迁移
// ---------------------------------------------------------------------------

// Download 下载整本,轮询进度,最后把产物迁移到 outputDir 并重命名。
// progress 回调(可空): (saved, total int)。
func (c *Client) Download(bookID, outputDir string, start, end int, progress func(saved, total int)) (string, error) {
	info, err := c.Preview(bookID)
	if err != nil {
		return "", fmt.Errorf("获取书籍信息失败: %w", err)
	}
	jobID, err := c.CreateJob(bookID, start, end)
	if err != nil {
		return "", err
	}

	lastState := ""
	for {
		js, err := c.JobStatus(jobID)
		if err != nil {
			return "", fmt.Errorf("查询任务失败: %w", err)
		}
		if js == nil {
			break
		}
		if js.State == "done" {
			break
		} else if js.State == "failed" {
			return "", errors.New(js.Message)
		} else if js.State == "cancelled" {
			return "", errors.New("已取消")
		}
		if progress != nil && (js.State == "running" || js.State == "pending") {
			progress(js.SavedChapters, js.ChapterTotal)
		}
		if js.State != lastState {
			lastState = js.State
		}
		time.Sleep(pollInterval)
	}

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", err
	}
	target := filepath.Join(outputDir, SafeFilename(info.Title)+" "+SafeFilename(info.Author)+".txt")
	return c.relocateOutput(info, target)
}

// relocateOutput 从服务器保存目录/库根目录找到产物,迁移/重命名到 target。
// 若产物是 epub,自动转 txt。
func (c *Client) relocateOutput(info *Book, target string) (string, error) {
	found := c.findOutput(info)
	if found == "" {
		return "", nil // 未找到(Rust 可能已保存但路径不一致)
	}
	if filepath.Ext(found) == ".epub" {
		txt, err := EpubToTxt(found)
		if err != nil {
			return "", fmt.Errorf("EPUB 转 TXT 失败: %w", err)
		}
		os.Remove(found)
		found = txt
	}
	if filepath.Dir(found) == filepath.Dir(target) && found == target {
		return target, nil
	}
	if err := os.Rename(found, target); err != nil {
		return "", err
	}
	return target, nil
}

// findOutput 在库根目录、缓存目录、Downloads 中找产物文件。
func (c *Client) findOutput(info *Book) string {
	var dirs []string
	if lib, err := c.apiGet("/api/library", nil); err == nil {
		if root := strOf(lib["root"]); root != "" {
			dirs = append(dirs, root)
		}
	}
	dirs = append(dirs, c.DataDir, c.SaveDir,
		filepath.Join(os.Getenv("HOME"), "Downloads"),
		filepath.Join(os.Getenv("HOME"), "downloads"))

	for _, dir := range dirs {
		if dir == "" || !dirExists(dir) {
			continue
		}
		// 库根目录递归找
		var walk func(string) string
		walk = func(d string) string {
			entries, err := os.ReadDir(d)
			if err != nil {
				return ""
			}
			for _, e := range entries {
				if e.IsDir() {
					if f := walk(filepath.Join(d, e.Name())); f != "" {
						return f
					}
					continue
				}
				if isTargetFile(info, e.Name()) {
					return filepath.Join(d, e.Name())
				}
			}
			return ""
		}
		if dir == dirs[0] {
			if f := walk(dir); f != "" {
				return f
			}
			continue
		}
		// 非库根目录只扫顶层
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() && isTargetFile(info, e.Name()) {
				return filepath.Join(dir, e.Name())
			}
		}
	}
	return ""
}

func isTargetFile(info *Book, name string) bool {
	ext := filepath.Ext(name)
	if ext != ".txt" && ext != ".epub" {
		return false
	}
	stem := strings.TrimSuffix(name, ext)
	return strings.Contains(stem, info.Title) || strings.Contains(stem, info.BookID)
}

// EpubToTxt 将 EPUB 转为 TXT(与 EPUB 同目录),返回 TXT 路径。
func EpubToTxt(epubPath string) (string, error) {
	txtPath := strings.TrimSuffix(epubPath, filepath.Ext(epubPath)) + ".txt"
	zr, err := zipReader(epubPath)
	if err != nil {
		return "", err
	}
	var parts []string
	for _, name := range zr.Names {
		lower := strings.ToLower(name)
		if !strings.HasSuffix(lower, ".xhtml") && !strings.HasSuffix(lower, ".html") {
			continue
		}
		if strings.Contains(lower, "toc") || strings.Contains(lower, "nav") || strings.Contains(lower, "cover") {
			continue
		}
		content, err := zr.Read(name)
		if err != nil {
			continue
		}
		body := extractBody(string(content))
		if body == "" {
			continue
		}
		parts = append(parts, body)
	}
	if len(parts) == 0 {
		return "", errors.New("epub 内无正文")
	}
	return txtPath, os.WriteFile(txtPath, []byte(strings.Join(parts, "\n\n")), 0644)
}

func extractBody(htmlStr string) string {
	re := regexp.MustCompile(`(?s)<body[^>]*>(.*?)</body>`)
	m := re.FindStringSubmatch(htmlStr)
	if m == nil {
		return ""
	}
	text := regexp.MustCompile(`<[^>]+>`).ReplaceAllString(m[1], "")
	text = html.UnescapeString(text)
	text = regexp.MustCompile(`\n\s*\n`).ReplaceAllString(text, "\n\n")
	return strings.TrimSpace(text)
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

func SafeFilename(name string) string {
	re := regexp.MustCompile(`[<>:"/\\|?*]`)
	s := re.ReplaceAllString(name, "")
	s = strings.Trim(s, ". ")
	if s == "" {
		return "未知"
	}
	return s
}

// FormatWords 数字转万字文案。5353368 → "535万字"。
func FormatWords(n int) string {
	if n >= 10000 {
		return fmt.Sprintf("%.0f万字", float64(n)/10000)
	}
	return fmt.Sprintf("%d字", n)
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func strOf(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return fmt.Sprintf("%.0f", t)
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
		n := 0
		fmt.Sscanf(t, "%d", &n)
		return n
	default:
		return 0
	}
}

func boolOf(v interface{}) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// zipReader 便于读取 epub。用 archive/zip + 内存读取,返回小助手。
type zipHelper struct {
	Names []string
	data  map[string][]byte
}

func (z *zipHelper) Read(name string) ([]byte, error) {
	if b, ok := z.data[name]; ok {
		return b, nil
	}
	return nil, errors.New("no such file: " + name)
}

func zipReader(path string) (*zipHelper, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	zr, err := zip.NewReader(f, st.Size())
	if err != nil {
		return nil, err
	}
	z := &zipHelper{data: map[string][]byte{}}
	for _, zf := range zr.File {
		rc, err := zf.Open()
		if err != nil {
			continue
		}
		b, _ := io.ReadAll(rc)
		rc.Close()
		z.Names = append(z.Names, zf.Name)
		z.data[zf.Name] = b
	}
	return z, nil
}
