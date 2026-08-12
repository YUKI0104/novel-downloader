package qimao

// 七猫(wtzw/qimao)下载器 —— 从 swiftcat.py 忠实移植。
// 参考: ~/.claude/skills/novel-down/scripts/swiftcat.py

import (
	"archive/zip"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	SignKey  = "d3dGiJc651gSQ8w1"
	AESKeyHex = "32343263636238323330643730396531"
)

var (
	aesKey, _ = hex.DecodeString(AESKeyHex)
	baseURLs  = map[string]string{
		"search":   "https://api-bc.wtzw.com",
		"detail":   "https://api-bc.wtzw.com",
		"download": "https://api-bc.wtzw.com",
		"catalog":  "https://api-ks.wtzw.com",
	}
	versions = []string{
		"73720", "73700", "73620", "73600", "73500", "73420", "73400",
		"73328", "73325", "73320", "73300", "73220", "73200", "73100",
		"73000", "72900", "72820", "72800", "70720", "62010", "62112",
	}
)

// ---------------------------------------------------------------------------
// 核心签名 / 哈希（与 Dart 应用一致）
// ---------------------------------------------------------------------------

// Sign 生成签名: sorted keys 的 "k=v" 拼接 + SIGN_KEY, md5 hex。
func sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var sb strings.Builder
	for _, k := range keys {
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(params[k])
	}
	sb.WriteString(SignKey)
	sum := md5.Sum([]byte(sb.String()))
	return hex.EncodeToString(sum[:])
}

// stableHash 模拟 Dart string.hashCode（确定性 signed 32-bit）。
func stableHash(s string) int32 {
	var h int64
	for _, ch := range s {
		h = (h*31 + int64(ch)) & 0xFFFFFFFF
	}
	if h >= 0x80000000 {
		h -= 0x100000000
	}
	return int32(h)
}

func requestHeaders(bookID string) http.Header {
	h := int64(0)
	if bookID != "" {
		h = int64(stableHash(bookID))
	}
	idx := 0
	if h < 0 {
		idx = int(-h % int64(len(versions)))
	} else {
		idx = int(h % int64(len(versions)))
	}
	version := versions[idx]

	hdrs := map[string]string{
		"AUTHORIZATION": "",
		"app-version":   version,
		"application-id": "com.****.reader",
		"channel":       "unknown",
		"net-env":       "1",
		"platform":      "android",
		"qm-params":     "",
		"reg":           "0",
	}
	hdrs["sign"] = sign(hdrs)

	hdr := http.Header{}
	for k, v := range hdrs {
		hdr.Set(k, v)
	}
	hdr.Set("User-Agent", "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
	return hdr
}

// ExtractBookID 归一化书号 / 链接 → 裸数字 ID。
func ExtractBookID(raw string) string {
	raw = strings.TrimSpace(raw)
	for _, pat := range []*regexp.Regexp{
		regexp.MustCompile(`qimao\.com/shuku/(\d+)`),
		regexp.MustCompile(`wtzw\.com/article-detail/(\d+)`),
	} {
		if m := pat.FindStringSubmatch(raw); m != nil {
			return m[1]
		}
	}
	if isAllDigits(raw) {
		return raw
	}
	return raw
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// SafeFilename 去掉非法文件名字符。
func SafeFilename(name string) string {
	re := regexp.MustCompile(`[<>:"/\\|?*]`)
	s := re.ReplaceAllString(name, "")
	s = strings.Trim(s, ". ")
	if s == "" {
		return "book"
	}
	return s
}

func stripHTML(s string) string {
	re := regexp.MustCompile(`<[^>]*>`)
	return re.ReplaceAllString(s, "")
}

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

type SearchResult struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Author   string `json:"author"`
	IsOver   bool   `json:"is_over"`
	Score    string `json:"score"`    // 评分,如 "9.7"
	Words    string `json:"words"`    // 字数,如 "536万字"
	CoverURL string `json:"coverUrl"` // 封面
}

type BookChapter struct {
	ID    string
	Title string
	Sort  int
}

// RankBook 七猫榜单书籍。
type RankBook struct {
	ID       string
	Title    string
	Author   string
	Words    string // 如 "891.33万字"
	Hot      string // 热度,如 "4373.5万"
	CoverURL string
	Intro    string
	IsOver   bool
	Category string
}

// AdaptBook 七猫官方「剧本改编书单」书籍。
type AdaptBook struct {
	ID       string
	Title    string
	Author   string
	Words    string // 如 "4.6万字"
	Category string
	IsOver   bool
	CoverURL string
	Intro    string
	ClientID int // 改编类型(如 1=漫剧/动漫, 3=短剧)
}

// AdaptOption 改编书单筛选选项。
type AdaptOption struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

// AdaptFilterGroup 一组筛选菜单(如「改编方向」「所属频道」)。
type AdaptFilterGroup struct {
	Key     string        `json:"key"`
	Label   string        `json:"label"`
	Options []AdaptOption `json:"options"`
}

// AdaptFilter 改编书单筛选条件(对应官方菜单)。
type AdaptFilter struct {
	Direction   string // 改编方向: ""全部 1动漫短剧 2真人短剧
	Channel     string // 频道: ""全部 0男生 1女生 2短故事
	Category    string // 分类: ""全部
	Words       string // 字数: ""全部 1~5
	IsOver      string // 完结: ""全部 1已完结 0连载中
	RankingType string // 热门书单: ""全部 1~6
	Page        int
	PageSize    int
}

type Book struct {
	BookID     string
	Title      string
	Author     string
	Intro      string
	WordsNum   int
	Tags       string
	ImgURL     string
	Score      string // 评分
	Hot        string // 人气/在读
	Rank       string // 榜单排名
	Category   string // 分类
	Characters string // 主角
}

// ---------------------------------------------------------------------------
// API Client
// ---------------------------------------------------------------------------

type Client struct {
	http *http.Client
}

func NewClient() *Client {
	return &Client{http: &http.Client{Timeout: 60 * time.Second}}
}

func (c *Client) get(baseKey, path string, params map[string]string, bookID string) (map[string]interface{}, error) {
	params["sign"] = sign(params)
	u := baseURLs[baseKey] + path
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	q := req.URL.Query()
	for k, v := range params {
		q.Set(k, v)
	}
	req.URL.RawQuery = q.Encode()
	req.Header = requestHeaders(bookID)

	resp, err := c.http.Do(req)
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

func (c *Client) Search(keyword string) ([]SearchResult, error) {
	data, err := c.get("search", "/search/v1/words", map[string]string{
		"extend":            "",
		"tab":               "0",
		"gender":            "0",
		"refresh_state":     "8",
		"page":              "1",
		"wd":                keyword,
		"is_short_story_user": "0",
	}, "00000000")
	if err != nil {
		return nil, err
	}
	var books []interface{}
	if dm, ok := data["data"].(map[string]interface{}); ok {
		books, _ = dm["books"].([]interface{})
	}
	var results []SearchResult
	for _, item := range books {
		it, _ := item.(map[string]interface{})
		id, _ := it["id"].(string)
		if id == "" {
			continue
		}
		results = append(results, SearchResult{
			ID:       id,
			Title:    stripHTML(strOf(it["title"])),
			Author:   stripHTML(strOf(it["author"])),
			IsOver:   strOf(it["is_over"]) == "1",
			Score:    strOf(it["score"]),
			Words:    extractWords(strOf(it["sub_title"])),
			CoverURL: strOf(it["image_link"]),
		})
	}
	return results, nil
}

func (c *Client) BookDetail(bookID string) (*Book, error) {
	data, err := c.get("detail", "/api/v4/book/detail", map[string]string{
		"id":         bookID,
		"imei_ip":    "2937357107",
		"teeny_mode": "0",
	}, bookID)
	if err != nil {
		return nil, err
	}
	dm, ok := data["data"].(map[string]interface{})
	if !ok {
		return nil, errors.New("detail: 无 data 字段")
	}
	b, ok := dm["book"].(map[string]interface{})
	if !ok {
		return nil, errors.New("detail: 无 book 字段")
	}
	var tags []string
	if list, ok := b["book_tag_list"].([]interface{}); ok {
		for _, t := range list {
			tt, _ := t.(map[string]interface{})
			if title := strOf(tt["title"]); title != "" {
				tags = append(tags, title)
			}
		}
	}
	attr, _ := b["attribute"].(map[string]interface{})
	return &Book{
		BookID:     firstNonEmpty(strOf(b["id"]), bookID),
		Title:      strOf(b["title"]),
		Author:     strOf(b["author"]),
		Intro:      strOf(b["intro"]),
		WordsNum:   intOf(b["words_num"]),
		Tags:       strings.Join(tags, ", "),
		ImgURL:     strOf(b["image_link"]),
		Score:      strOf(attr["score"]),
		Hot:        composeHot(attr),
		Rank:       cleanRank(strOf(attr["rank_title"])),
		Category:   strings.TrimSpace(strOf(b["category1_name"]) + " " + strOf(b["category2_name"])),
		Characters: firstNonEmpty(strOf(attr["characters"]), strOf(b["characters"])),
	}, nil
}

func (c *Client) ChapterList(bookID string) ([]BookChapter, error) {
	data, err := c.get("catalog", "/api/v1/chapter/chapter-list", map[string]string{
		"chapter_ver": "0",
		"id":          bookID,
	}, bookID)
	if err != nil {
		return nil, err
	}
	raw, _ := data["data"].(map[string]interface{})["chapter_lists"].([]interface{})
	chapters := make([]BookChapter, 0, len(raw))
	for _, item := range raw {
		it, _ := item.(map[string]interface{})
		chapters = append(chapters, BookChapter{
			ID:    strOf(it["id"]),
			Title: strOf(it["title"]),
			Sort:  intOf(it["chapter_sort"]),
		})
	}
	sort.SliceStable(chapters, func(i, j int) bool { return chapters[i].Sort < chapters[j].Sort })
	return chapters, nil
}

// ---------------------------------------------------------------------------
// 排行榜(七猫官网 web API,普通浏览器请求即可,无需 app 签名)
// ---------------------------------------------------------------------------

const qimaoRankAPI = "https://www.qimao.com/qimaoapi/api/rank/book-list"

// RankingBooks 返回七猫榜单书籍(前20)。
// isGirl: "0"=男生 "1"=女生; rankType: 1大热 2新书 3完结 4收藏 6更新。
func (c *Client) RankingBooks(isGirl, rankType string) ([]RankBook, error) {
	params := url.Values{}
	params.Set("is_girl", isGirl)
	params.Set("rank_type", rankType)
	params.Set("page", "1")
	if rankType == "4" || rankType == "6" {
		params.Set("date_type", "1")
	} else {
		params.Set("date_type", "2")
	}
	req, err := http.NewRequest(http.MethodGet, qimaoRankAPI+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("七猫榜单 HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Data struct {
			TableData []map[string]interface{} `json:"table_data"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	books := make([]RankBook, 0, len(payload.Data.TableData))
	for _, it := range payload.Data.TableData {
		id := strOf(it["book_id"])
		if id == "" {
			continue
		}
		hot := strings.TrimSpace(strOf(it["number"]) + strOf(it["unit"]))
		cat := strings.TrimSpace(strOf(it["category1_name"]) + " " + strOf(it["category2_name"]))
		books = append(books, RankBook{
			ID:       id,
			Title:    strOf(it["title"]),
			Author:   strOf(it["author"]),
			Words:    strOf(it["words_num"]),
			Hot:      hot,
			CoverURL: strOf(it["image_link"]),
			Intro:    strOf(it["intro"]),
			IsOver:   strOf(it["is_over"]) == "1",
			Category: cat,
		})
	}
	return books, nil
}

// ---------------------------------------------------------------------------
// 官方「剧本改编书单」(作者中心 API)
// ---------------------------------------------------------------------------

const (
	qimaoAdaptAPI    = "https://zuozhe.qimao.com/api/pc/v1/book/screenplay-ranking-list"
	qimaoAdaptCfgAPI = "https://zuozhe.qimao.com/api/pc/v1/book/screenplay-ranking-config"
)

// adaptFetch 带作者中心 UA/Referer 的 GET 请求。
func (c *Client) adaptFetch(rawURL string) (map[string]interface{}, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	req.Header.Set("Referer", "https://zuozhe.qimao.com/front/screenplay/adapt-book-list")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("改编接口 HTTP %d", resp.StatusCode)
	}
	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

// AdaptRankConfig 返回官方改编书单的筛选菜单(方向/频道/分类/字数/完结/热门书单)。
func (c *Client) AdaptRankConfig() ([]AdaptFilterGroup, error) {
	data, err := c.adaptFetch(qimaoAdaptCfgAPI)
	if err != nil {
		return nil, err
	}
	raw, _ := data["data"].([]interface{})
	groups := make([]AdaptFilterGroup, 0, len(raw))
	for _, item := range raw {
		m, _ := item.(map[string]interface{})
		g := AdaptFilterGroup{Key: strOf(m["key"]), Label: strOf(m["label"])}
		if opts, ok := m["options"].([]interface{}); ok {
			for _, o := range opts {
				om, _ := o.(map[string]interface{})
				g.Options = append(g.Options, AdaptOption{Label: strOf(om["label"]), Value: strOf(om["value"])})
			}
		}
		groups = append(groups, g)
	}
	return groups, nil
}

// AdaptBookList 按筛选条件返回改编书单(分页)。返回书籍列表与总数。
func (c *Client) AdaptBookList(f AdaptFilter) ([]AdaptBook, int, error) {
	if f.PageSize <= 0 {
		f.PageSize = 20
	}
	if f.Page <= 0 {
		f.Page = 1
	}
	params := url.Values{}
	params.Set("direction", f.Direction)
	params.Set("channel", f.Channel)
	params.Set("category", f.Category)
	params.Set("words", f.Words)
	params.Set("is_over", f.IsOver)
	params.Set("ranking_type", f.RankingType)
	params.Set("date_type", "1")
	params.Set("page_size", strconv.Itoa(f.PageSize))
	params.Set("page", strconv.Itoa(f.Page))
	data, err := c.adaptFetch(qimaoAdaptAPI + "?" + params.Encode())
	if err != nil {
		return nil, 0, err
	}
	dm, _ := data["data"].(map[string]interface{})
	raw, _ := dm["book_list"].([]interface{})
	books := make([]AdaptBook, 0, len(raw))
	for _, item := range raw {
		it, _ := item.(map[string]interface{})
		id := strconv.FormatInt(int64(intOf(it["book_id"])), 10)
		if id == "0" {
			continue
		}
		books = append(books, AdaptBook{
			ID:       id,
			Title:    strOf(it["book_title"]),
			Author:   strOf(it["author_name"]),
			Words:    wordsText(it["words_num"]),
			Category: strOf(it["category1_name"]),
			IsOver:   strOf(it["is_over"]) == "完结",
			CoverURL: strOf(it["image_link"]),
			Intro:    strOf(it["intro"]),
			ClientID: intOf(it["client_id"]),
		})
	}
	total := 0
	if pd, ok := dm["page_data"].(map[string]interface{}); ok {
		total = intOf(pd["count"])
	}
	return books, total, nil
}

// wordsText 从 words_num 结构 {number,value,unit,title} 拼 "4.6万字"。
func wordsText(v interface{}) string {
	wn, ok := v.(map[string]interface{})
	if !ok {
		return ""
	}
	return strings.TrimSpace(strOf(wn["value"]) + strOf(wn["unit"]) + strOf(wn["title"]))
}

func (c *Client) DownloadURL(bookID string) (string, error) {
	data, err := c.get("download", "/api/v1/book/download", map[string]string{
		"id":     bookID,
		"source": "1",
		"type":   "2",
		"is_vip": "1",
	}, bookID)
	if err != nil {
		return "", err
	}
	link := ""
	if dm, ok := data["data"].(map[string]interface{}); ok {
		link = strOf(dm["link"])
	}
	return link, nil
}

func (c *Client) DownloadZip(link string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, link, nil)
	if err != nil {
		return nil, err
	}
	req.Header = requestHeaders("")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("下载数据包失败: HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// Decrypt AES-128-CBC 解密单章。base64 → 前16字节为 IV → 剩余为密文。失败返回原文。
func Decrypt(text string) string {
	raw, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(raw) < 16 {
		return text
	}
	iv, ct := raw[:16], raw[16:]
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return text
	}
	if len(ct)%block.BlockSize() != 0 {
		return text
	}
	plain := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, ct)
	// PKCS7 unpadding
	if n := len(plain); n > 0 {
		pad := int(plain[n-1])
		if pad >= 1 && pad <= 16 && pad <= n {
			plain = plain[:n-pad]
		}
	}
	return string(plain)
}

// ---------------------------------------------------------------------------
// 下载 zip → 章节映射
// ---------------------------------------------------------------------------

// UnzipChapters 解压加密 zip,按章节 ID(文件名去扩展名)解密映射。
func UnzipChapters(zipBytes []byte) (map[string]string, error) {
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return nil, err
	}
	m := make(map[string]string)
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			continue
		}
		chID := strings.TrimSuffix(f.Name, ".txt")
		m[chID] = Decrypt(string(b))
	}
	return m, nil
}

// Download 整本下载:详情 + 目录 + 下载zip + 解密 + 写文件。
// format: "txt" | "epub"。progress 回调 (done, total)。
func (c *Client) Download(bookID, outputDir, format string, progress func(done, total int)) (string, error) {
	book, err := c.BookDetail(bookID)
	if err != nil {
		return "", err
	}
	catalog, err := c.ChapterList(bookID)
	if err != nil {
		return "", err
	}
	dlURL, err := c.DownloadURL(bookID)
	if err != nil {
		return "", err
	}
	zipBytes, err := c.DownloadZip(dlURL)
	if err != nil {
		return "", err
	}
	chapters, err := UnzipChapters(zipBytes)
	if err != nil {
		return "", err
	}
	var ordered []OrderedChapter
	for i, ch := range catalog {
		if content, ok := chapters[ch.ID]; ok {
			ordered = append(ordered, OrderedChapter{Chapter: ch, Content: content})
		}
		if progress != nil {
			progress(i+1, len(catalog))
		}
	}
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", err
	}
	base := SafeFilename(book.Title) + " " + SafeFilename(book.Author)
	switch format {
	case "epub":
		path := filepath.Join(outputDir, base+".epub")
		return path, WriteEpub(book, ordered, path, book.ImgURL)
	default:
		path := filepath.Join(outputDir, base+".txt")
		return path, WriteSingleTxt(book, ordered, path)
	}
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

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

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// extractWords 从 "影视・影视原著・完结・536万字" 这类文本提取 "536万字"。
func extractWords(s string) string {
	re := regexp.MustCompile(`(\d+(?:\.\d+)?万?字)`)
	if m := re.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	return ""
}

// composeHot 从 attribute 拼人气/在读文案,如 "265.9万 人气 · 22.2万 在读"。
func composeHot(attr map[string]interface{}) string {
	var parts []string
	if pop := strOf(attr["popularity"]); pop != "" && pop != "0" {
		parts = append(parts, pop+"万 人气")
	}
	if read := strOf(attr["reading"]); read != "" && read != "0" {
		parts = append(parts, read+"万 在读")
	}
	return strings.Join(parts, " · ")
}

// cleanRank 去掉 "穿越突围好书,当前排第###7###名" 中的 ### 标记。
func cleanRank(s string) string {
	if s == "" {
		return ""
	}
	re := regexp.MustCompile(`#+(\d+)#+`)
	return strings.TrimSpace(re.ReplaceAllString(s, "$1"))
}

// FormatWords 数字转万字文案。5353368 → "535万字"。
func FormatWords(n int) string {
	if n >= 10000 {
		return fmt.Sprintf("%.0f万字", float64(n)/10000)
	}
	return fmt.Sprintf("%d字", n)
}
