package main

// 后端诊断日志:追加写入 appSupportDir()/app.log,用户可从设置里一键导出。
// 用于排查搜索空结果、反爬拦截等环境相关问题。

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const maxLogSize = 5 * 1024 * 1024 // 超过 5MB 截断重建,防止无限增长

var (
	logMu   sync.Mutex
	logFile *os.File
)

// initLog 打开日志文件(追加模式),文件过大时重建。
func initLog() {
	logMu.Lock()
	dir := appSupportDir()
	os.MkdirAll(dir, 0755)
	path := filepath.Join(dir, "app.log")
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxLogSize {
		os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		logFile = f
	}
	logMu.Unlock()
	appLog("=== 应用启动 ===") // 释放锁后再写,避免重复加锁死锁
}

// appLog 写一行带时间戳的日志。
func appLog(format string, args ...interface{}) {
	logMu.Lock()
	defer logMu.Unlock()
	if logFile == nil {
		return
	}
	line := fmt.Sprintf("%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
	logFile.WriteString(line)
	logFile.Sync()
}

// logPath 返回日志文件路径。
func logPath() string {
	return filepath.Join(appSupportDir(), "app.log")
}
