//go:build !windows

package fanqie

import (
	"os/exec"
	"syscall"
)

// configureProcessGroup 让内核成为独立进程组组长,退出时可整组回收
// (内核若 fork 出子进程,只 kill 父 PID 会留下孤儿)。
func configureProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killProcess 先杀整个进程组(pgid == 组长 pid),再杀该 pid。
func killProcess(pid int) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	_ = syscall.Kill(pid, syscall.SIGKILL)
}

// processAlive 判断 pid 是否存活(signal 0 探测)。
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
