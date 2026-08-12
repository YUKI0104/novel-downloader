package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"

	"novel-downloader/fanqie"
	"novel-downloader/qimao"
)

// Settings 应用设置。
type Settings struct {
	DownloadDir string `json:"downloadDir"` // 下载目录
	Format      string `json:"format"`      // txt | epub
	FanqieBin   string `json:"fanqieBin"`   // Rust binary 路径(空=自动查找 ~/bin)
}

func (s Settings) withDefaults() Settings {
	if s.DownloadDir == "" {
		s.DownloadDir = filepath.Join(os.Getenv("HOME"), "Downloads")
	}
	if s.Format == "" {
		s.Format = "txt"
	}
	return s
}

// SearchItem 搜索结果。
type SearchItem struct {
	Platform string `json:"platform"`
	BookID   string `json:"bookId"`
	Title    string `json:"title"`
	Author   string `json:"author"`
	Abstract string `json:"abstract"`
	IsOver   bool   `json:"isOver"`
	Score    string `json:"score"`
	Words    string `json:"words"`
	Hot      string `json:"hot"`
	CoverURL string `json:"coverUrl"`
}

// BookInfo 书籍详情。
type BookInfo struct {
	Platform     string `json:"platform"`
	BookID       string `json:"bookId"`
	Title        string `json:"title"`
	Author       string `json:"author"`
	Description  string `json:"description"`
	ChapterCount int    `json:"chapterCount"`
	CoverURL     string `json:"coverUrl"`
	Tags         string `json:"tags"`
	IsOver       bool   `json:"isOver"`
	Score        string `json:"score"`
	Words        string `json:"words"`
	Hot          string `json:"hot"`
	Rank         string `json:"rank"`
	Category     string `json:"category"`
	Characters   string `json:"characters"`
}

// DownloadRecord 下载记录(软件自己下载的文件)。
type DownloadRecord struct {
	Path     string `json:"path"`
	Title    string `json:"title"`
	Author   string `json:"author"`
	Format   string `json:"format"`   // txt | epub
	Platform string `json:"platform"` // qimao | fanqie
	Time     string `json:"time"`     // RFC3339
}

// LibraryItem 已下载文件(列表展示用)。
type LibraryItem struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Ext      string `json:"ext"`
	Platform string `json:"platform"`
	Time     string `json:"time"`
}

// RankGenre 单个类型榜单。
type RankGenre struct {
	Name    string `json:"name"`
	ReadURL string `json:"readUrl"`
	NewURL  string `json:"newUrl"`
}

// RankCategory 排行榜分组(综合/男频/女频)。
type RankCategory struct {
	Gender string      `json:"gender"`
	HotURL string      `json:"hotUrl"`
	Genres []RankGenre `json:"genres"`
}

// RankedBook 榜单书籍(含名次)。
type RankedBook struct {
	Position int    `json:"position"`
	Platform string `json:"platform"`
	BookID   string `json:"bookId"`
	Title    string `json:"title"`
	Author   string `json:"author"`
	Words    string `json:"words"`
	Hot      string `json:"hot"`
	Score    string `json:"score"`
	CoverURL string `json:"coverUrl"`
}

// App 是 Wails 绑定主体。
type App struct {
	ctx      context.Context
	qimao    *qimao.Client
	fanqie   *fanqie.Client
	settings Settings

	mu   sync.Mutex // 保护 settings
	dlMu sync.Mutex // 同一时刻只允许一个下载任务
}

// NewApp 创建 App。
func NewApp() *App {
	return &App{}
}

// startup 启动时保存 ctx 并加载设置。
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.settings = a.loadSettings()
	a.initClients()
}

// shutdown 退出时停止番茄服务。
func (a *App) shutdown(ctx context.Context) {
	a.fanqie.StopServer()
}

// bundledFanqieBin 返回 .app 内置的番茄内核路径(Contents/Resources)。
func bundledFanqieBin() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	p := filepath.Join(filepath.Dir(exe), "..", "Resources", "Tomato-Novel-Downloader")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

// resolveFanqieBin 解析内核路径:用户设置 → 内置 → ~/bin。
func resolveFanqieBin(configured string) string {
	if configured != "" {
		if _, err := os.Stat(configured); err == nil {
			return configured
		}
	}
	if b := bundledFanqieBin(); b != "" {
		return b
	}
	return filepath.Join(os.Getenv("HOME"), "bin", "Tomato-Novel-Downloader")
}

func (a *App) initClients() {
	a.qimao = qimao.NewClient()
	// 内核 save_path 用应用私有目录:避免每次预览书都把封面/临时目录写进用户下载文件夹
	kernelDir := filepath.Join(appSupportDir(), "downloads")
	a.fanqie = fanqie.NewClient(resolveFanqieBin(a.settings.FanqieBin), "", kernelDir)
}

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

// appSupportDir 返回应用数据目录(测试可用 NOVEL_SETTINGS_DIR 隔离)。
func appSupportDir() string {
	if dir := os.Getenv("NOVEL_SETTINGS_DIR"); dir != "" {
		return dir
	}
	return filepath.Join(os.Getenv("HOME"), "Library", "Application Support", "novel-downloader")
}

func settingsPath() string {
	dir := appSupportDir()
	os.MkdirAll(dir, 0755)
	return filepath.Join(dir, "settings.json")
}

func (a *App) loadSettings() Settings {
	var s Settings
	if b, err := os.ReadFile(settingsPath()); err == nil {
		json.Unmarshal(b, &s)
	}
	return s.withDefaults()
}

func (a *App) saveSettings() error {
	b, _ := json.MarshalIndent(a.settings, "", "  ")
	return os.WriteFile(settingsPath(), b, 0644)
}

// GetSettings 返回当前设置。
func (a *App) GetSettings() Settings {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.settings
}

// SetSettings 保存设置。
func (a *App) SetSettings(s Settings) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.settings = s.withDefaults()
	a.saveSettings()
	a.initClients()
}

// DefaultSettings 返回默认设置。
func (a *App) DefaultSettings() Settings {
	return Settings{}.withDefaults()
}

// ---------------------------------------------------------------------------
// 搜索 / 详情
// ---------------------------------------------------------------------------

// Search 跨平台搜索。
func (a *App) Search(platform, keyword string) ([]SearchItem, error) {
	switch platform {
	case "fanqie":
		if err := a.fanqie.EnsureServer(); err != nil {
			return nil, err
		}
		rs, err := a.fanqie.Search(keyword)
		if err != nil {
			return nil, err
		}
		items := make([]SearchItem, 0, len(rs))
		for _, r := range rs {
			items = append(items, SearchItem{
				Platform: "fanqie", BookID: r.BookID, Title: r.Title,
				Author: r.Author, Abstract: r.Abstract,
				Score: r.Score, Words: r.Words, Hot: r.Hot, CoverURL: r.CoverURL,
			})
		}
		return items, nil
	default: // qimao
		rs, err := a.qimao.Search(keyword)
		if err != nil {
			return nil, err
		}
		items := make([]SearchItem, 0, len(rs))
		for _, r := range rs {
			items = append(items, SearchItem{
				Platform: "qimao", BookID: r.ID, Title: r.Title,
				Author: r.Author, IsOver: r.IsOver,
				Score: r.Score, Words: r.Words, CoverURL: r.CoverURL,
			})
		}
		return items, nil
	}
}

// BookInfo 获取书籍详情。
func (a *App) BookInfo(platform, bookID string) (*BookInfo, error) {
	switch platform {
	case "fanqie":
		if err := a.fanqie.EnsureServer(); err != nil {
			return nil, err
		}
		b, err := a.fanqie.Preview(bookID)
		if err != nil {
			return nil, err
		}
		return &BookInfo{
			Platform: "fanqie", BookID: b.BookID, Title: b.Title, Author: b.Author,
			Description: b.Description, ChapterCount: b.ChapterCount, CoverURL: a.fanqie.ResolveCover(b.CoverURL),
			Words: b.Words, Hot: b.Hot, Score: b.Score, Category: b.Category,
		}, nil
	default:
		id := qimao.ExtractBookID(bookID)
		b, err := a.qimao.BookDetail(id)
		if err != nil {
			return nil, err
		}
		chapterCount := 0
		if chapters, err := a.qimao.ChapterList(id); err == nil {
			chapterCount = len(chapters)
		}
		words := ""
		if b.WordsNum > 0 {
			words = qimao.FormatWords(b.WordsNum)
		}
		return &BookInfo{
			Platform: "qimao", BookID: b.BookID, Title: b.Title, Author: b.Author,
			Description: b.Intro, Tags: b.Tags, CoverURL: b.ImgURL,
			ChapterCount: chapterCount,
			Score: b.Score, Words: words, Hot: b.Hot, Rank: b.Rank,
			Category: b.Category, Characters: b.Characters,
		}, nil
	}
}

// ---------------------------------------------------------------------------
// 排行榜
// ---------------------------------------------------------------------------

// RankingCategories 返回番茄排行榜分组(综合/男频/女频)。
func (a *App) RankingCategories() ([]RankCategory, error) {
	raw, err := fanqie.RankCategories()
	if err != nil {
		return nil, err
	}
	out := make([]RankCategory, 0, len(raw))
	for _, r := range raw {
		g := RankCategory{Gender: r.Gender, HotURL: r.HotURL}
		for _, genre := range r.Genres {
			g.Genres = append(g.Genres, RankGenre{
				Name: genre.Name, ReadURL: genre.ReadURL, NewURL: genre.NewURL,
			})
		}
		out = append(out, g)
	}
	return out, nil
}

// RankingBooks 返回指定榜单的书籍列表(前10)。
func (a *App) RankingBooks(rankURL string) ([]RankedBook, error) {
	if err := a.fanqie.EnsureServer(); err != nil {
		return nil, err
	}
	books, err := a.fanqie.RankingBooks(rankURL)
	if err != nil {
		return nil, err
	}
	out := make([]RankedBook, 0, len(books))
	for i, b := range books {
		out = append(out, RankedBook{
			Position: i + 1,
			Platform: "fanqie",
			BookID:   b.BookID,
			Title:    b.Title,
			Author:   b.Author,
			Words:    b.Words,
			Hot:      b.Hot,
			Score:    b.Score,
			CoverURL: a.fanqie.ResolveCover(b.CoverURL),
		})
	}
	return out, nil
}

// QimaoAdaptBooks 七猫官方剧本改编书单(前20)。direction: "" 全部, "1" 动漫短剧, "2" 真人短剧。
func (a *App) QimaoAdaptBooks(direction string) ([]RankedBook, error) {
	books, err := a.qimao.AdaptBookList(direction)
	if err != nil {
		return nil, err
	}
	out := make([]RankedBook, 0, len(books))
	for i, b := range books {
		out = append(out, RankedBook{
			Position: i + 1,
			Platform: "qimao",
			BookID:   b.ID,
			Title:    b.Title,
			Author:   b.Author,
			Words:    b.Words,
			CoverURL: b.CoverURL,
		})
	}
	return out, nil
}

// QimaoRankBooks 七猫榜单书籍(前20)。isGirl: 0=男生 1=女生; rankType: 1大热 2新书 3完结 4收藏 6更新。
func (a *App) QimaoRankBooks(isGirl, rankType string) ([]RankedBook, error) {
	books, err := a.qimao.RankingBooks(isGirl, rankType)
	if err != nil {
		return nil, err
	}
	out := make([]RankedBook, 0, len(books))
	for i, b := range books {
		out = append(out, RankedBook{
			Position: i + 1,
			Platform: "qimao",
			BookID:   b.ID,
			Title:    b.Title,
			Author:   b.Author,
			Words:    b.Words,
			Hot:      b.Hot,
			CoverURL: b.CoverURL,
		})
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// 下载
// ---------------------------------------------------------------------------

// Download 异步下载,通过事件下载进度。
func (a *App) Download(platform, bookID string) {
	go func() {
		a.dlMu.Lock()
		defer a.dlMu.Unlock()

		dir := a.settings.DownloadDir
		format := a.settings.Format
		runtime.EventsEmit(a.ctx, "download:start", map[string]interface{}{
			"platform": platform, "bookId": bookID,
		})

		emitProgress := func(saved, total int) {
			runtime.EventsEmit(a.ctx, "download:progress", map[string]interface{}{
				"platform": platform, "bookId": bookID, "saved": saved, "total": total,
			})
		}

		var path, title, author string
		var err error
		switch platform {
		case "fanqie":
			if e := a.fanqie.EnsureServer(); e != nil {
				err = e
				break
			}
			path, err = a.fanqie.Download(bookID, dir, 0, 0, emitProgress)
			if info, e := a.fanqie.Preview(bookID); e == nil {
				title, author = info.Title, info.Author
			}
		default:
			id := qimao.ExtractBookID(bookID)
			path, err = a.qimao.Download(id, dir, format, emitProgress)
			if info, e := a.qimao.BookDetail(id); e == nil {
				title, author = info.Title, info.Author
			}
		}

		if err != nil {
			runtime.EventsEmit(a.ctx, "download:error", map[string]interface{}{
				"platform": platform, "bookId": bookID, "message": err.Error(),
			})
			return
		}
		// 登记下载记录(已下载列表只显示这些)
		recFormat := format
		if platform == "fanqie" {
			recFormat = "txt"
		}
		a.addRecord(DownloadRecord{
			Path: path, Title: title, Author: author,
			Format: recFormat, Platform: platform,
			Time: time.Now().Format(time.RFC3339),
		})
		runtime.EventsEmit(a.ctx, "download:done", map[string]interface{}{
			"platform": platform, "bookId": bookID, "path": path,
			"title": title, "author": author,
		})
	}()
}

// ---------------------------------------------------------------------------
// 已下载
// ---------------------------------------------------------------------------

// Library 列出已下载记录(仅软件下载的,不扫目录)。
func (a *App) Library() []LibraryItem {
	recs := a.loadRecords()
	items := make([]LibraryItem, 0, len(recs))
	for _, r := range recs {
		fi, err := os.Stat(r.Path)
		if err != nil || fi.IsDir() {
			continue // 文件已不存在则跳过
		}
		items = append(items, LibraryItem{
			Name:     fi.Name(),
			Path:     r.Path,
			Size:     fi.Size(),
			Ext:      stringsTrimDot(filepath.Ext(fi.Name())),
			Platform: r.Platform,
			Time:     r.Time,
		})
	}
	return items
}

// RemoveLibraryItem 删除已下载项。deleteFile=true 时同时删除本地文件。
func (a *App) RemoveLibraryItem(path string, deleteFile bool) error {
	recs := a.loadRecords()
	var out []DownloadRecord
	removed := false
	for _, r := range recs {
		if r.Path == path {
			removed = true
			if deleteFile {
				if err := os.Remove(r.Path); err != nil && !os.IsNotExist(err) {
					return err
				}
			}
			continue
		}
		out = append(out, r)
	}
	if !removed {
		return errors.New("未找到该下载记录")
	}
	return a.saveRecords(out)
}

// ---------------------------------------------------------------------------
// 下载记录持久化
// ---------------------------------------------------------------------------

func recordsPath() string {
	dir := appSupportDir()
	os.MkdirAll(dir, 0755)
	return filepath.Join(dir, "downloads.json")
}

func (a *App) loadRecords() []DownloadRecord {
	var recs []DownloadRecord
	if b, err := os.ReadFile(recordsPath()); err == nil {
		json.Unmarshal(b, &recs)
	}
	return recs
}

func (a *App) saveRecords(recs []DownloadRecord) error {
	b, _ := json.MarshalIndent(recs, "", "  ")
	return os.WriteFile(recordsPath(), b, 0644)
}

func (a *App) addRecord(r DownloadRecord) {
	recs := a.loadRecords()
	recs = append(recs, r)
	a.saveRecords(recs)
}

// OpenFolder 在 Finder 中显示文件/目录。
func (a *App) OpenFolder(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return err
	}
	if fi.IsDir() {
		return exec.Command("open", path).Start()
	}
	return exec.Command("open", "-R", path).Start()
}

// PickDirectory 弹出系统目录选择框。
func (a *App) PickDirectory() (string, error) {
	return runtime.OpenDirectoryDialog(a.ctx, runtime.OpenDialogOptions{
		Title: "选择下载目录",
	})
}

func stringsTrimDot(s string) string {
	if len(s) > 0 && s[0] == '.' {
		return s[1:]
	}
	return s
}
