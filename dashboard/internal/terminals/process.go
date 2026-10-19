package terminals

import (
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Process handling talks to Windows directly (no PowerShell): it works the
// same from 32- and 64-bit builds and from a dashboard started in the
// background, where spawning PowerShell proved unreliable.

const exe = "terminal64.exe"

const (
	processQueryLimitedInformation = 0x1000
	synchronize                    = 0x00100000
	wmClose                        = 0x0010
)

var (
	kernel32                  = syscall.NewLazyDLL("kernel32.dll")
	user32                    = syscall.NewLazyDLL("user32.dll")
	procQueryFullProcessImage = kernel32.NewProc("QueryFullProcessImageNameW")
	procEnumWindows           = user32.NewProc("EnumWindows")
	procGetWindowThreadPID    = user32.NewProc("GetWindowThreadProcessId")
	procIsWindowVisible       = user32.NewProc("IsWindowVisible")
	procPostMessage           = user32.NewProc("PostMessageW")
)

func normDir(dir string) string { return strings.ToLower(filepath.Clean(dir)) }

// Start launches a portable MT5. configIni (optional) is an MT5 /config file.
func Start(dir, configIni string) error {
	args := []string{"/portable"}
	if configIni != "" {
		args = append(args, "/config:"+configIni)
	}
	cmd := exec.Command(filepath.Join(dir, exe), args...)
	cmd.Dir = dir
	return cmd.Start()
}

// mt5Processes maps the install folder of every running MT5 to its PIDs.
func mt5Processes() map[string][]uint32 {
	found := map[string][]uint32{}
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return found
	}
	defer syscall.CloseHandle(snap)
	var e syscall.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = syscall.Process32First(snap, &e); err == nil; err = syscall.Process32Next(snap, &e) {
		if !strings.EqualFold(syscall.UTF16ToString(e.ExeFile[:]), exe) {
			continue
		}
		if p := imagePath(e.ProcessID); p != "" {
			dir := normDir(filepath.Dir(p))
			found[dir] = append(found[dir], e.ProcessID)
		}
	}
	return found
}

func imagePath(pid uint32) string {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, pid)
	if err != nil {
		return ""
	}
	defer syscall.CloseHandle(h)
	buf := make([]uint16, syscall.MAX_LONG_PATH)
	n := uint32(len(buf))
	if r, _, _ := procQueryFullProcessImage.Call(uintptr(h), 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n))); r == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:n])
}

// RunningDirs returns the install folders of every running MT5.
func RunningDirs() map[string]bool {
	dirs := map[string]bool{}
	for d := range mt5Processes() {
		dirs[d] = true
	}
	return dirs
}

// Stop closes an MT5 the way clicking X does (WM_CLOSE to its windows), so it
// saves its state - including the chart with the EA - for the next start.
// Waits up to 30 s for it to exit.
func Stop(dir string) error {
	pids := mt5Processes()[normDir(dir)]
	for _, pid := range pids {
		closeWindows(pid)
	}
	for _, pid := range pids {
		if h, err := syscall.OpenProcess(synchronize, false, pid); err == nil {
			syscall.WaitForSingleObject(h, uint32((30 * time.Second).Milliseconds()))
			syscall.CloseHandle(h)
		}
	}
	return nil
}

func closeWindows(pid uint32) {
	cb := syscall.NewCallback(func(hwnd, _ uintptr) uintptr {
		var owner uint32
		procGetWindowThreadPID.Call(hwnd, uintptr(unsafe.Pointer(&owner)))
		if owner == pid {
			if visible, _, _ := procIsWindowVisible.Call(hwnd); visible != 0 {
				procPostMessage.Call(hwnd, wmClose, 0, 0)
			}
		}
		return 1 // keep enumerating
	})
	procEnumWindows.Call(cb, 0)
}
