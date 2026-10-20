package terminals

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unicode/utf16"
)

var eaFiles = []string{"CopierMaster.ex5", "CopierFollower.ex5"}

// copyMT5 copies the program files of an MT5 install, not its accounts,
// history or logs, so the new install starts clean. serversFrom is the
// servers.dat to use (see bestServerList).
func copyMT5(src, serversFrom, dst string) error {
	for _, name := range []string{"terminal64.exe", "MetaEditor64.exe", "Terminal.ico"} {
		if err := copyFile(filepath.Join(src, name), filepath.Join(dst, name)); err != nil && name != "Terminal.ico" {
			return err
		}
	}
	for _, dir := range []string{"Sounds", "Profiles"} {
		if err := copyTree(filepath.Join(src, dir), filepath.Join(dst, dir)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	// The broker server list: without the account's server in it, MT5 can't
	// connect (it only learns new brokers through File > Open an Account).
	copyFile(serversFrom, filepath.Join(dst, "Config", "servers.dat"))
	return nil
}

// bestServerList picks the servers.dat most likely to know `server`: an
// added account on that same server, else the biggest list among added
// accounts (it has learned the most brokers), else the source install's.
func bestServerList(accounts []Account, server, source string) string {
	best, bestSize := filepath.Join(source, "Config", "servers.dat"), int64(0)
	for _, a := range accounts {
		p := filepath.Join(a.Dir, "Config", "servers.dat")
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if a.Server == server {
			return p
		}
		if info.Size() > bestSize {
			best, bestSize = p, info.Size()
		}
	}
	return best
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		return copyFile(p, filepath.Join(dst, rel))
	})
}

// writeUTF16 writes text the way MT5 writes its own .ini/.set files
// (UTF-16LE with BOM, CRLF line ends).
func writeUTF16(path, text string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var buf bytes.Buffer
	buf.Write([]byte{0xFF, 0xFE})
	for _, u := range utf16.Encode([]rune(strings.ReplaceAll(text, "\n", "\r\n"))) {
		buf.WriteByte(byte(u))
		buf.WriteByte(byte(u >> 8))
	}
	return os.WriteFile(path, buf.Bytes(), 0o600)
}

// startupIni is an MT5 /config file: log in (and save the password in MT5)
// and allow algo trading. The EA itself is attached via the profile chart
// (writeEAChart), which unlike [StartUp] survives restarts.
func startupIni(login, password, server string) string {
	return fmt.Sprintf("[Common]\nLogin=%s\nPassword=%s\nServer=%s\nKeepPrivate=1\nNewsEnable=0\n", login, password, server) +
		"[Experts]\nAllowLiveTrading=1\nAllowDllImport=0\nEnabled=1\nAccount=0\nProfile=0\n"
}

var compileResultRe = regexp.MustCompile(`(\d+) errors?, (\d+) warnings?`)

// compileEAs copies the EA sources into a terminal that already has MT5's
// standard library (created on its first run) and compiles them there.
func compileEAs(mql5Src, terminalDir string) error {
	for _, sub := range []string{`Include\TradeCopier`, `Experts\TradeCopier`} {
		if err := copyTree(filepath.Join(mql5Src, sub), filepath.Join(terminalDir, "MQL5", sub)); err != nil {
			return fmt.Errorf("copy EA sources: %w", err)
		}
	}
	for _, ea := range []string{"CopierMaster.mq5", "CopierFollower.mq5"} {
		src := filepath.Join(terminalDir, "MQL5", "Experts", "TradeCopier", ea)
		log := strings.TrimSuffix(src, ".mq5") + ".log"
		cmd := exec.Command(filepath.Join(terminalDir, "MetaEditor64.exe"), "/portable", "/compile:"+src, "/log:"+log)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		cmd.Run() // MetaEditor's exit code isn't reliable; the log is
		raw, _ := os.ReadFile(log)
		m := compileResultRe.FindStringSubmatch(decodeUTF16(raw))
		if m == nil || m[1] != "0" {
			return fmt.Errorf("compiling %s failed - see %s", ea, log)
		}
	}
	return nil
}

func decodeUTF16(b []byte) string {
	b = bytes.TrimPrefix(b, []byte{0xFF, 0xFE})
	u := make([]uint16, len(b)/2)
	for i := range u {
		u[i] = uint16(b[2*i]) | uint16(b[2*i+1])<<8
	}
	return string(utf16.Decode(u))
}

// installEAs copies the compiled EAs into a terminal.
func installEAs(buildDir, terminalDir string) error {
	for _, f := range eaFiles {
		if err := copyFile(filepath.Join(buildDir, f), filepath.Join(terminalDir, "MQL5", "Experts", "TradeCopier", f)); err != nil {
			return errors.New("compiled EAs not found")
		}
	}
	return nil
}

// cacheBuild saves a terminal's compiled EAs as the build to install from.
func cacheBuild(terminalDir, buildDir string) error {
	for _, f := range eaFiles {
		if err := copyFile(filepath.Join(terminalDir, "MQL5", "Experts", "TradeCopier", f), filepath.Join(buildDir, f)); err != nil {
			return err
		}
	}
	return nil
}
