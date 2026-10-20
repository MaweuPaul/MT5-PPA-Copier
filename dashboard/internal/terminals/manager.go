// Package terminals creates, starts and stops the portable MT5 installs the
// copier runs in, so adding an account is one form in the dashboard instead
// of a manual setup in MT5.
//
// Passwords are only ever written to a one-time MT5 start-up file that is
// deleted seconds after MT5 reads it; MT5 then keeps the login itself
// (encrypted, "Save password"). Nothing here stores them.
package terminals

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"
)

const (
	RoleMaster   = "master"
	RoleFollower = "follower"
)

// Settings are the dashboard's own paths (setup.json).
type Settings struct {
	MT5Source    string `json:"mt5_source"`    // an installed MT5 to copy from
	TerminalsDir string `json:"terminals_dir"` // one sub-folder per account
}

// Account is one registered MT5 install (accounts.json).
type Account struct {
	Login  string `json:"login"`
	Server string `json:"server"`
	Role   string `json:"role"`
	Dir    string `json:"dir"`
	// Set for an MT5 that was attached rather than created by the dashboard.
	// DataDir is where its MQL5 folder lives (under %APPDATA% for a normal,
	// non-portable install); empty means portable (same as Dir).
	DataDir  string `json:"data_dir,omitempty"`
	Attached bool   `json:"attached,omitempty"`
}

// Data is the folder holding this MT5's MQL5, Config and logs.
func (a Account) Data() string {
	if a.DataDir != "" {
		return a.DataDir
	}
	return a.Dir
}

func (a Account) Portable() bool { return normDir(a.Data()) == normDir(a.Dir) }

// Start launches this account's MT5 (portable or not).
func (a Account) Start() error { return Start(a.Dir, "", a.Portable()) }

type Manager struct {
	root    string // TradeCopier folder in Common Files
	mql5Dir string // repo MQL5 sources, for compiling the EAs
	mu      sync.Mutex
	jobs    map[string]*Job
}

func New(root, mql5Dir string) *Manager {
	return &Manager{root: root, mql5Dir: mql5Dir, jobs: map[string]*Job{}}
}

func (m *Manager) path(name string) string { return filepath.Join(m.root, name) }

// buildDir caches the compiled EAs (.ex5); scripts/deploy.ps1 refreshes it too.
func (m *Manager) buildDir() string { return m.path("build") }

func (m *Manager) Settings() Settings {
	s := Settings{MT5Source: `C:\Program Files\MetaTrader 5`, TerminalsDir: defaultTerminalsDir()}
	jsonfile.Read(m.path("setup.json"), &s)
	return s
}

func (m *Manager) SaveSettings(s Settings) error {
	if !exists(filepath.Join(s.MT5Source, "terminal64.exe")) {
		return errors.New("no terminal64.exe in the MT5 folder")
	}
	if s.TerminalsDir == "" {
		return errors.New("choose a folder for the accounts")
	}
	return jsonfile.Write(m.path("setup.json"), s)
}

func defaultTerminalsDir() string {
	if exists(`D:\MT5`) {
		return `D:\MT5`
	}
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "TradeCopier", "terminals")
}

func (m *Manager) Accounts() []Account {
	var list []Account
	jsonfile.Read(m.path("accounts.json"), &list)
	sort.Slice(list, func(i, j int) bool {
		if list[i].Role != list[j].Role {
			return list[i].Role == RoleMaster // master first
		}
		return list[i].Login < list[j].Login
	})
	return list
}

// AccountStatus is a registered account plus whether its MT5 is running.
type AccountStatus struct {
	Account
	Running bool `json:"running"`
}

func (m *Manager) Statuses() []AccountStatus {
	running := RunningDirs()
	out := []AccountStatus{}
	for _, a := range m.Accounts() {
		out = append(out, AccountStatus{a, running[normDir(a.Dir)]})
	}
	return out
}

// Find returns a registered account by login.
func (m *Manager) Find(login string) (Account, bool) {
	for _, a := range m.Accounts() {
		if a.Login == login {
			return a, true
		}
	}
	return Account{}, false
}

func (m *Manager) saveAccount(a Account) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := m.Accounts()
	for i := range list {
		if list[i].Login == a.Login {
			list[i] = a
			return jsonfile.Write(m.path("accounts.json"), list)
		}
	}
	return jsonfile.Write(m.path("accounts.json"), append(list, a))
}

// Remove closes an account's MT5 and unregisters it. With deleteFolder the
// MT5 folder (its saved login, history and logs) is deleted too - but only a
// folder that really is an MT5 install inside the accounts folder. The
// account is unregistered even if the folder can't be deleted; the error
// then says what's left.
func (m *Manager) Remove(login string, deleteFolder bool) (Account, error) {
	a, ok := m.Find(login)
	if !ok {
		return a, errors.New("unknown account")
	}
	Stop(a.Dir)
	if err := m.unregister(login); err != nil {
		return a, err
	}
	if deleteFolder {
		if err := m.deleteInstall(a.Dir); err != nil {
			return a, fmt.Errorf("removed from the dashboard, but the folder wasn't deleted: %w", err)
		}
	}
	return a, nil
}

func (m *Manager) unregister(login string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	keep := []Account{}
	for _, x := range m.Accounts() {
		if x.Login != login {
			keep = append(keep, x)
		}
	}
	return jsonfile.Write(m.path("accounts.json"), keep)
}

// deleteInstall refuses anything that isn't a direct sub-folder of the
// accounts folder containing terminal64.exe, so a bad registry entry can
// never delete something else.
func (m *Manager) deleteInstall(dir string) error {
	root := normDir(m.Settings().TerminalsDir)
	if normDir(filepath.Dir(dir)) != root || !exists(filepath.Join(dir, exe)) {
		return fmt.Errorf("not deleting %s: it isn't an MT5 folder inside %s - delete it yourself", dir, m.Settings().TerminalsDir)
	}
	if RunningDirs()[normDir(dir)] {
		return fmt.Errorf("not deleting %s: its MT5 is still running - close it and delete the folder yourself", dir)
	}
	// Windows can keep files locked for a moment after MT5 exits; retry briefly.
	var err error
	for attempt := 0; attempt < 10; attempt++ {
		if err = os.RemoveAll(dir); err == nil {
			return nil
		}
		time.Sleep(time.Second)
	}
	return err
}

// StartAll launches every registered MT5 that isn't running (dashboard
// start-up and the "Launch all" button) and returns how many it started.
// The master goes first so followers find it publishing.
func (m *Manager) StartAll() int {
	running, started := RunningDirs(), 0
	for _, a := range m.Accounts() { // master is sorted first
		if !running[normDir(a.Dir)] && a.Start() == nil {
			started++
		}
	}
	return started
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }
