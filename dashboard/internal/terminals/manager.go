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
	"os"
	"path/filepath"
	"sort"
	"sync"

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
}

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

func (m *Manager) find(login string) (Account, bool) {
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

// Remove unregisters an account after closing its MT5. The folder is kept
// (it holds MT5's saved login and logs); the dashboard tells the user where.
func (m *Manager) Remove(login string) (Account, error) {
	a, ok := m.find(login)
	if !ok {
		return a, errors.New("unknown account")
	}
	Stop(a.Dir)
	m.mu.Lock()
	defer m.mu.Unlock()
	keep := []Account{}
	for _, x := range m.Accounts() {
		if x.Login != login {
			keep = append(keep, x)
		}
	}
	return a, jsonfile.Write(m.path("accounts.json"), keep)
}

// StartAll launches every registered MT5 that isn't running (dashboard start-up).
func (m *Manager) StartAll() {
	running := RunningDirs()
	for _, a := range m.Accounts() {
		if !running[normDir(a.Dir)] {
			Start(a.Dir, "")
		}
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }
