//go:build windows

package fanqie

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

// CREATE_NEW_PROCESS_GROUP: 让内核拥有独立进程组。
const createNewProcessGroup = 0x00000200

func configureProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}
}

// killProcess 用 taskkill /T 连同子进程一起结束。
func killProcess(pid int) {
	if pid <= 0 {
		return
	}
	_ = exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(pid)).Run()
}

// processAlive 在 Windows 上保守返回 true(无法可靠探测时避免误清 PID 文件)。
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	_ = p
	return true
}
