package terminals

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Attaching an MT5 the user already has (e.g. a prop firm's own install,
// already logged in). Nothing is copied and no password is needed: the
// copier is added to that MT5 on a chart of its own, next to the user's.

// AttachRequest is the "An MT5 I already have" form.
type AttachRequest struct {
	Role   string `json:"role"`
	Folder string `json:"folder"` // the folder with terminal64.exe
}

// Existing describes an MT5 install found on disk.
type Existing struct {
	Dir     string
	DataDir string
	Login   string
	Server  string
	Profile string
}

var (
	iniLoginRe   = regexp.MustCompile(`(?m)^Login=(\d+)\s*$`)
	iniServerRe  = regexp.MustCompile(`(?m)^Server=(.+?)\s*$`)
	iniProfileRe = regexp.MustCompile(`(?m)^ProfileLast=(.+?)\s*$`)
)

// Inspect finds an MT5's data folder and the account it last logged in to.
func Inspect(folder string) (Existing, error) {
	dir := filepath.Clean(strings.Trim(strings.TrimSpace(folder), `"`))
	if !exists(filepath.Join(dir, exe)) {
		return Existing{}, fmt.Errorf("no %s in %s - pick the folder MT5 is installed in", exe, dir)
	}
	data := findDataDir(dir)
	// common.ini has the saved login, but MT5 only writes it on exit; the
	// journal (loginFromLogs, below) covers a running or brand-new MT5.
	raw, _ := os.ReadFile(filepath.Join(data, "Config", "common.ini"))
	ini := decodeUTF16(raw)
	e := Existing{Dir: dir, DataDir: data, Profile: "Default"}
	if m := iniLoginRe.FindStringSubmatch(ini); m != nil {
		e.Login = m[1]
	}
	if m := iniServerRe.FindStringSubmatch(ini); m != nil {
		e.Server = m[1]
	}
	if m := iniProfileRe.FindStringSubmatch(ini); m != nil {
		e.Profile = m[1]
	}
	// A running MT5 may not have written its login to common.ini yet.
	if login, server, ok := loginFromLogs(data); ok {
		e.Login, e.Server = login, server
	}
	if e.Login == "" || e.Server == "" {
		return Existing{}, errors.New("this MT5 isn't logged in to an account - log in once with Save password, then try again")
	}
	return e, nil
}

// findDataDir: a portable install keeps its MQL5 folder next to
// terminal64.exe; a normal one keeps it in %APPDATA%\MetaQuotes\Terminal\<id>,
// whose origin.txt names the install folder. Decide by MQL5, not Config:
// a normal install has a small Config folder of its own, and MT5 also
// creates an AppData folder (with origin.txt) for portable installs.
func findDataDir(dir string) string {
	if exists(filepath.Join(dir, "MQL5")) {
		return dir
	}
	origins, _ := filepath.Glob(filepath.Join(os.Getenv("APPDATA"), "MetaQuotes", "Terminal", "*", "origin.txt"))
	for _, o := range origins {
		raw, err := os.ReadFile(o)
		if err == nil && normDir(strings.TrimSpace(decodeUTF16(raw))) == normDir(dir) {
			return filepath.Dir(o)
		}
	}
	return dir
}

// Attach checks the folder now (so the form can show errors straight away)
// and sets the copier up in the background. It returns the job id and the
// account it found.
func (m *Manager) Attach(r AttachRequest, followerInputs func(login string) []string) (string, Existing, error) {
	if r.Role != RoleMaster && r.Role != RoleFollower {
		return "", Existing{}, errors.New("choose main account or copy account")
	}
	e, err := Inspect(r.Folder)
	if err != nil {
		return "", e, err
	}
	if _, ok := m.Find(e.Login); ok {
		return "", e, fmt.Errorf("account %s is already added", e.Login)
	}
	for _, a := range m.Accounts() {
		if normDir(a.Dir) == normDir(e.Dir) {
			return "", e, fmt.Errorf("this MT5 is already added (account %s)", a.Login)
		}
	}
	if !m.buildReady() {
		return "", e, errors.New("no compiled copier yet - add one account the normal way first, or run scripts\\deploy.ps1")
	}
	id := strconv.FormatInt(time.Now().UnixNano(), 36)
	job := &Job{}
	m.mu.Lock()
	m.jobs[id] = job
	m.mu.Unlock()
	inputs := []string{}
	if r.Role == RoleFollower {
		inputs = followerInputs(e.Login)
	}
	go func() { job.finish(m.attach(job, r.Role, e, inputs)) }()
	return id, e, nil
}

func (m *Manager) attach(job *Job, role string, e Existing, inputs []string) error {
	job.step("Found account %s on %s", e.Login, e.Server)
	// MT5 rewrites its profile on exit, so it must be closed while we add the chart.
	if RunningDirs()[normDir(e.Dir)] {
		job.step("Closing that MT5 for a moment…")
		Stop(e.Dir)
	}
	if err := installEAs(m.buildDir(), e.DataDir); err != nil {
		return err
	}
	ea := "CopierMaster"
	if role == RoleFollower {
		ea = "CopierFollower"
	}
	file, already, err := nextChartFile(e.DataDir, e.Profile)
	if err != nil {
		return err
	}
	if already {
		job.step("The copier is already on a chart in this MT5 - leaving it as it is")
	} else {
		job.step("Adding the copier on a new chart (your charts aren't changed)…")
		if err := writeEAChart(e.DataDir, e.Profile, file, "EURUSD", ea, inputs); err != nil {
			return err
		}
	}
	acc := Account{Login: e.Login, Server: e.Server, Role: role, Dir: e.Dir, Attached: true}
	if normDir(e.DataDir) != normDir(e.Dir) {
		acc.DataDir = e.DataDir
	}
	if err := m.saveAccount(acc); err != nil {
		return err
	}
	job.step("Starting MT5 with Algo Trading on…")
	// No login in this config: MT5 reconnects with its saved password.
	path := filepath.Join(e.DataDir, iniName)
	if err := writeUTF16(path, "[Experts]\nAllowLiveTrading=1\nAllowDllImport=0\nEnabled=1\nAccount=0\nProfile=0\n"); err != nil {
		return err
	}
	if err := Start(e.Dir, path, acc.Portable()); err != nil {
		return err
	}
	time.AfterFunc(iniReadTimeout, func() { os.Remove(path) })
	if !waitUntil(func() bool { return loggedIn(e.DataDir, e.Server) }, loginWait) {
		return fmt.Errorf("MT5 started but didn't log in to %s - open it and log in with Save password ticked", e.Server)
	}
	job.step("Done - the account appears on the Overview within a few seconds.")
	return nil
}

// nextChartFile returns a free chartNN.chr name in the profile, or
// already=true if a chart there already runs the copier (never add twice:
// two copiers on one account would copy every trade twice).
func nextChartFile(dataDir, profile string) (string, bool, error) {
	dir := filepath.Join(dataDir, "MQL5", "Profiles", "Charts", profile)
	files, _ := filepath.Glob(filepath.Join(dir, "chart*.chr"))
	used := map[string]bool{}
	for _, f := range files {
		used[strings.ToLower(filepath.Base(f))] = true
		if raw, err := os.ReadFile(f); err == nil {
			text := decodeUTF16(raw)
			if strings.Contains(text, `TradeCopier\CopierFollower`) || strings.Contains(text, `TradeCopier\CopierMaster`) {
				return "", true, nil
			}
		}
	}
	for i := 1; i < 100; i++ {
		name := fmt.Sprintf("chart%02d.chr", i)
		if !used[name] {
			return name, false, nil
		}
	}
	return "", false, errors.New("this MT5 profile has too many charts - close some and try again")
}
