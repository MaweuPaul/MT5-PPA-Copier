package terminals

import (
	"fmt"
	"os"
	"path/filepath"
)

// Start-with-Windows is a .cmd in the user's Startup folder that runs the
// dashboard, which in turn starts every registered MT5 (main.go -launch).
func startupCmd() string {
	return filepath.Join(os.Getenv("APPDATA"), `Microsoft\Windows\Start Menu\Programs\Startup`, "TradeCopier.cmd")
}

func AutostartEnabled() bool { return exists(startupCmd()) }

func SetAutostart(enabled bool) error {
	if !enabled {
		if err := os.Remove(startupCmd()); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := fmt.Sprintf("@echo off\r\nstart \"\" /min \"%s\" -open=false\r\n", self)
	return os.WriteFile(startupCmd(), []byte(cmd), 0o644)
}
