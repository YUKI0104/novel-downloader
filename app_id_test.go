package main

import (
	"context"
	"os"
	"testing"
)

// TestSearchByID 验证按 book_id / 书页链接直接搜索。
func TestSearchByID(t *testing.T) {
	os.Setenv("NOVEL_SETTINGS_DIR", t.TempDir())
	a := NewApp()
	a.startup(context.Background())
	defer a.shutdown(context.Background())

	const wantID = "7649259001011522622"

	for _, kw := range []string{
		wantID,
		"https://fanqienovel.com/page/" + wantID,
	} {
		items, err := a.Search("fanqie", kw)
		if err != nil {
			t.Fatalf("按 ID 搜索(%s)失败: %v", kw, err)
		}
		if len(items) != 1 || items[0].BookID != wantID {
			t.Fatalf("按 ID 搜索(%s)结果异常: %+v", kw, items)
		}
		t.Logf("✅ 按 ID 命中: %s / %s", items[0].Title, items[0].Author)
	}

	// 详情应显示当前书名 + 曾用名
	info, err := a.BookInfo("fanqie", wantID)
	if err != nil {
		t.Fatalf("BookInfo 失败: %v", err)
	}
	t.Logf("详情书名=%q 曾用名=%q", info.Title, info.FormerTitle)
	if info.Title != "买卖词条，打造非凡俱乐部" {
		t.Errorf("详情应显示网页当前书名, got %q", info.Title)
	}
	if info.FormerTitle != "五万买下十年阳寿，反手十亿卖出" {
		t.Errorf("应提示曾用名, got %q", info.FormerTitle)
	}
}