package main

import (
	"context"
	"os"
	"testing"
)

// TestE2E 验证 App 绑定的核心链路(搜索/详情/环境),无需 GUI。
func TestE2E(t *testing.T) {
	// 隔离设置/记录目录,避免测试污染真实配置
	os.Setenv("NOVEL_SETTINGS_DIR", t.TempDir())
	a := NewApp()
	a.startup(context.Background())
	defer a.shutdown(context.Background())

	// 七猫搜索
	items, err := a.Search("qimao", "斗破苍穹")
	if err != nil {
		t.Fatalf("qimao search: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("qimao search 无结果")
	}
	t.Logf("✅ 七猫: %d 条, 首条=%s / %s / 评分=%s 字数=%s 封面=%v",
		len(items), items[0].Title, items[0].Author, items[0].Score, items[0].Words, items[0].CoverURL != "")
	if items[0].Words == "" {
		t.Errorf("七猫搜索应含字数, got: %+v", items[0])
	}
	qimaoID := items[0].BookID

	// 番茄搜索
	items, err = a.Search("fanqie", "斗破苍穹")
	if err != nil {
		t.Fatalf("fanqie search: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("fanqie search 无结果")
	}
	t.Logf("✅ 番茄: %d 条, 首条=%s / %s", len(items), items[0].Title, items[0].Author)

	// 七猫详情(用七猫的 ID)
	info, err := a.BookInfo("qimao", qimaoID)
	if err != nil {
		t.Fatalf("qimao bookinfo: %v", err)
	}
	if info.Title == "" {
		t.Fatal("详情标题为空")
	}
	t.Logf("✅ 七猫详情: %s / %s / %d章 / 热度=%s 榜单=%s 评分=%s",
		info.Title, info.Author, info.ChapterCount, info.Hot, info.Rank, info.Score)
	if info.Hot == "" && info.Rank == "" {
		t.Logf("⚠️ 七猫详情未取到热度/榜单(可能该书无榜单数据)")
	}

	// 番茄详情(用番茄的 ID)
	info, err = a.BookInfo("fanqie", items[0].BookID)
	if err != nil {
		t.Fatalf("fanqie bookinfo: %v", err)
	}
	if info.Title == "" {
		t.Fatal("番茄详情标题为空")
	}
	t.Logf("✅ 番茄详情: %s / %s / %d章", info.Title, info.Author, info.ChapterCount)

	// 排行榜(分组: 综合/男频/女频)
	cats, err := a.RankingCategories()
	if err != nil {
		t.Fatalf("ranking categories: %v", err)
	}
	if len(cats) == 0 {
		t.Fatal("排行榜分组为空")
	}
	t.Logf("✅ 榜单分组: %d 组", len(cats))
	for _, g := range cats {
		t.Logf("   - %s (类型 %d 个)", g.Gender, len(g.Genres))
	}
	// 综合热榜
	ranked, err := a.RankingBooks(cats[0].HotURL)
	if err != nil {
		t.Fatalf("hot rank books: %v", err)
	}
	if len(ranked) == 0 {
		t.Fatal("综合热榜为空")
	}
	t.Logf("✅ 综合热榜榜首: #%d %s / %s / %s", ranked[0].Position, ranked[0].Title, ranked[0].Author, ranked[0].Words)
	// 男频首个类型(阅读榜)
	if len(cats) > 1 && len(cats[1].Genres) > 0 {
		gen := cats[1].Genres[0]
		r2, err := a.RankingBooks(gen.ReadURL)
		if err != nil {
			t.Fatalf("genre rank: %v", err)
		}
		t.Logf("✅ %s·%s 榜首: #%d %s", cats[1].Gender, gen.Name, r2[0].Position, r2[0].Title)
	}

	// 七猫排行榜(男生大热榜)
	qbooks, err := a.QimaoRankBooks("0", "1")
	if err != nil {
		t.Fatalf("qimao rank: %v", err)
	}
	if len(qbooks) == 0 {
		t.Fatal("七猫大热榜为空")
	}
	t.Logf("✅ 七猫·男生大热榜: %d 本, 榜首=#%d %s / %s / %s",
		len(qbooks), qbooks[0].Position, qbooks[0].Title, qbooks[0].Author, qbooks[0].Words)
	// 女生新书榜
	qf, err := a.QimaoRankBooks("1", "2")
	if err != nil {
		t.Fatalf("qimao female rank: %v", err)
	}
	if len(qf) == 0 {
		t.Fatal("七猫女生新书榜为空")
	}
	t.Logf("✅ 七猫·女生新书榜榜首: %s / %s", qf[0].Title, qf[0].Author)

	// 七猫改编书单(筛选+分页)
	cfg, err := a.QimaoAdaptConfig()
	if err != nil {
		t.Fatalf("qimao adapt config: %v", err)
	}
	t.Logf("✅ 改编书单筛选菜单: %d 组 (%v)", len(cfg), cfg[0].Key+"/"+cfg[0].Label)
	adapts, err := a.QimaoAdaptBooks("", "", "", "", "", "", 1)
	if err != nil {
		t.Fatalf("qimao adapt: %v", err)
	}
	if len(adapts.Books) == 0 {
		t.Fatal("七猫改编书单为空")
	}
	t.Logf("✅ 七猫改编书单: 共 %d 本/%d 页, 榜首=#%d %s / %s / %s",
		adapts.Total, adapts.Pages, adapts.Books[0].Position, adapts.Books[0].Title, adapts.Books[0].Author, adapts.Books[0].Words)
	// 方向筛选(真人短剧)
	filtered, err := a.QimaoAdaptBooks("2", "", "", "", "", "", 1)
	if err != nil || len(filtered.Books) == 0 {
		t.Fatalf("qimao adapt filter: %v", err)
	}
	t.Logf("✅ 改编书单·真人短剧: %d 本, 榜首=%s", len(filtered.Books), filtered.Books[0].Title)

	// 设置往返
	a.SetSettings(Settings{DownloadDir: t.TempDir(), Format: "epub"})
	got := a.GetSettings()
	if got.Format != "epub" {
		t.Fatalf("设置未生效: %+v", got)
	}
	t.Logf("✅ 设置: dir=%s format=%s", got.DownloadDir, got.Format)
}
