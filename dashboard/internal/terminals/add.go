package terminals

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// AddRequest is the "Add account" form. Password is used once, never stored.
type AddRequest struct {
	Role       string  `json:"role"`
	Login      string  `json:"login"`
	Password   string  `json:"password"`
	Server     string  `json:"server"`
	MasterID   string  `json:"master_id"` // followers only
	Multiplier float64 `json:"multiplier"`
	Suffix     string  `json:"symbol_suffix"`
	// Copy delays (followers): fixed + random extra, in ms. The API saves
	// them, with the lot size and suffix, as the follower's dashboard config.
	DelayMs            int `json:"delay_ms"`
	DelayJitterMs      int `json:"delay_jitter_ms"`
	CloseDelayMs       int `json:"close_delay_ms"`
	CloseDelayJitterMs int `json:"close_delay_jitter_ms"`
}

// JobStatus is the progress of adding an account; the UI polls it.
type JobStatus struct {
	Steps []string `json:"steps"`
	Done  bool     `json:"done"`
	Error string   `json:"error,omitempty"`
}

// Job is a JobStatus being updated by the background setup.
type Job struct {
	mu sync.Mutex
	JobStatus
}

func (j *Job) step(format string, a ...any) {
	j.mu.Lock()
	j.Steps = append(j.Steps, fmt.Sprintf(format, a...))
	j.mu.Unlock()
}

func (j *Job) finish(err error) {
	j.mu.Lock()
	if err != nil {
		j.Error = err.Error()
	}
	j.Done = true
	j.mu.Unlock()
}

// Snapshot is a copy that's safe to encode while the job keeps running.
func (j *Job) Snapshot() JobStatus {
	j.mu.Lock()
	defer j.mu.Unlock()
	return JobStatus{Steps: append([]string(nil), j.Steps...), Done: j.Done, Error: j.Error}
}

var (
	loginRe  = regexp.MustCompile(`^[0-9]{1,20}$`)
	serverRe = regexp.MustCompile(`^[\w .\-()]{2,64}$`)
	suffixRe = regexp.MustCompile(`^[\w.\-#]{0,16}$`)
)

func (r AddRequest) validate() error {
	switch {
	case r.Role != RoleMaster && r.Role != RoleFollower:
		return errors.New("choose main account or copy account")
	case !loginRe.MatchString(r.Login):
		return errors.New("login must be the account number")
	case r.Password == "" || len(r.Password) > 64 || containsLineBreak(r.Password):
		return errors.New("enter the account's trading password")
	case !serverRe.MatchString(r.Server):
		return errors.New("enter the broker server exactly as MT5 shows it, e.g. Pepperstone-Demo")
	case r.Role == RoleFollower && !loginRe.MatchString(r.MasterID):
		return errors.New("enter the main account's login")
	case r.Role == RoleFollower && (r.Multiplier < 0.01 || r.Multiplier > 100):
		return errors.New("lot size must be between 0.01 and 100")
	case !suffixRe.MatchString(r.Suffix):
		return errors.New("symbol ending: up to 16 letters/digits, e.g. m")
	}
	return nil
}

func containsLineBreak(s string) bool {
	for _, c := range s {
		if c == '\n' || c == '\r' {
			return true // would let a value inject extra lines into the .ini
		}
	}
	return false
}

// Add validates the form and starts setting the account up in the background.
// The returned id is used to poll the job.
func (m *Manager) Add(r AddRequest) (string, error) {
	if err := r.validate(); err != nil {
		return "", err
	}
	if _, ok := m.Find(r.Login); ok {
		return "", errors.New("this account is already added")
	}
	s := m.Settings()
	if !exists(filepath.Join(s.MT5Source, exe)) {
		return "", errors.New("set the MT5 install folder in Setup first")
	}
	id := strconv.FormatInt(time.Now().UnixNano(), 36)
	job := &Job{}
	m.mu.Lock()
	m.jobs[id] = job
	m.mu.Unlock()
	go func() { job.finish(m.add(job, r, s)) }()
	return id, nil
}

func (m *Manager) Job(id string) (JobStatus, bool) {
	m.mu.Lock()
	j, ok := m.jobs[id]
	m.mu.Unlock()
	if !ok {
		return JobStatus{}, false
	}
	return j.Snapshot(), true
}

const (
	iniName        = "tradecopier-start.ini"
	firstRunWait   = 90 * time.Second // MT5 unpacks its standard library on first start
	iniReadTimeout = 20 * time.Second // MT5 reads /config within a few seconds
)

func (m *Manager) add(job *Job, r AddRequest, s Settings) error {
	dir := filepath.Join(s.TerminalsDir, r.Login)
	if exists(dir) {
		return fmt.Errorf("folder %s already exists - remove it or pick another accounts folder", dir)
	}
	job.step("Creating MT5 for %s in %s", r.Login, dir)
	if err := copyMT5(s.MT5Source, bestServerList(m.Accounts(), r.Server, s.MT5Source), dir); err != nil {
		return fmt.Errorf("copy MT5: %w", err)
	}

	ea, inputs := "CopierMaster", []string{}
	if r.Role == RoleFollower {
		ea = "CopierFollower"
		inputs = []string{"MasterId=" + r.MasterID, fmt.Sprintf("LotMultiplier=%g", r.Multiplier), "SymbolSuffix=" + r.Suffix}
	}
	// Any symbol the broker has works; the EA trades by the master's symbols.
	if err := writeEAChart(dir, "Default", "chart01.chr", "EURUSD"+r.Suffix, ea, inputs); err != nil {
		return err
	}

	// Compiled EAs come from the build cache. The very first account has none
	// yet: start it once without the EA so MT5 creates its standard library,
	// compile there, then restart with the EA.
	if installEAs(m.buildDir(), dir) != nil {
		job.step("First account: starting MT5 once to prepare the EAs (up to a minute)…")
		if err := m.launch(dir, startupIni(r.Login, r.Password, r.Server)); err != nil {
			return err
		}
		if !waitUntil(func() bool { return exists(filepath.Join(dir, "MQL5", "Include", "Trade", "Trade.mqh")) }, firstRunWait) {
			return errors.New("MT5 didn't finish its first start - check it opened, then try again")
		}
		job.step("Compiling the copier EAs…")
		if err := compileEAs(m.mql5Dir, dir); err != nil {
			return err
		}
		if err := cacheBuild(dir, m.buildDir()); err != nil {
			return err
		}
		Stop(dir)
	}

	job.step("Logging in to %s and attaching the copier…", r.Server)
	if err := m.launch(dir, startupIni(r.Login, r.Password, r.Server)); err != nil {
		return err
	}
	if err := m.saveAccount(Account{Login: r.Login, Server: r.Server, Role: r.Role, Dir: dir}); err != nil {
		return err
	}

	job.step("Waiting for MT5 to log in (up to a minute)…")
	if !waitUntil(func() bool { return loggedIn(dir, r.Server) }, loginWait) {
		// Usually MT5 doesn't know this broker's server yet. Searching for the
		// broker once teaches it; later accounts there then copy that list.
		return fmt.Errorf("MT5 started but couldn't log in to %s. In the new MT5 window: "+
			"File → Open an Account → search your broker → Connect with an existing trade account → "+
			"enter this login, password and server, tick Save password. The account is added and will "+
			"copy once it's connected. (If the password or server was mistyped, Remove it and add it again.)", r.Server)
	}
	job.step("Logged in. Done - the account appears on the Overview within a few seconds.")
	return nil
}

const loginWait = 60 * time.Second

func waitUntil(ok func() bool, timeout time.Duration) bool {
	for deadline := time.Now().Add(timeout); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		if ok() {
			return true
		}
	}
	return false
}

// launch starts MT5 with a one-time config holding the password, and deletes
// the file once MT5 has had time to read it.
func (m *Manager) launch(dir, ini string) error {
	path := filepath.Join(dir, iniName)
	if err := writeUTF16(path, ini); err != nil {
		return err
	}
	if err := Start(dir, path, true); err != nil {
		os.Remove(path)
		return fmt.Errorf("start MT5: %w", err)
	}
	time.AfterFunc(iniReadTimeout, func() { os.Remove(path) })
	return nil
}

// RemoveLeftoverInis deletes start-up files a crash may have left behind,
// so a password never stays on disk.
func (m *Manager) RemoveLeftoverInis() {
	for _, a := range m.Accounts() {
		os.Remove(filepath.Join(a.Dir, iniName))
	}
	files, _ := filepath.Glob(filepath.Join(m.Settings().TerminalsDir, "*", iniName))
	for _, f := range files {
		os.Remove(f)
	}
}
