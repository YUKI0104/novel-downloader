package main

import (
	"context"
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()

	err := wails.Run(&options.App{
		Title:         "番茄猫下载器",
		Width:         1100,
		Height:        780,
		DisableResize: true, // 固定窗口,不可放大/缩小
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 242, G: 242, B: 247, A: 1},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		// 关窗/退出前先把番茄内核收干净(幂等,失败不影响关闭);
		// 内核在独立进程组里,StopServer 会整组回收,不再留后台孤儿。
		OnBeforeClose: func(ctx context.Context) (prevent bool) {
			app.shutdown(ctx)
			return false
		},
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
