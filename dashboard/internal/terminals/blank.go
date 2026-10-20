package terminals

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// "Open a new MT5 and I'll log in there": the dashboard prepares a fresh MT5
// with the copier already on its chart and opens it; the user logs in inside
// MT5 (whose own broker search always finds the right server), and the
// dashboard registers the account as soon as MT5 has saved the login.

const blankLoginWait = 10 * time.Minute

// OpenBlank starts the setup in the background and returns the job id.
// onLogin runs once the account is known (e.g. to save its settings).
func (m *Manager) OpenBlank(role string, inputs []string, onLogin func(login string) error) (string, error) {
	if role != RoleMaster && role != RoleFollower {
		return "", errors.New("choose main account or copy account")
	}
	s := m.Settings()
	if !exists(filepath.Join(s.MT5Source, exe)) {
		return "", errors.New("set the MT5 install folder in Setup first")
	}
	if !m.buildReady() {
		return "", errors.New("no compiled copier yet - add one account with \"Set up a new MT5\" first, or run scripts\\deploy.ps1")
	}
	id := strconv.FormatInt(time.Now().UnixNano(), 36)
	job := &Job{}
	m.mu.Lock()
	m.jobs[id] = job
	m.mu.Unlock()
	go func() { job.finish(m.openBlank(job, role, inputs, onLogin, s)) }()
	return id, nil
}

func (m *Manager) openBlank(job *Job, role string, inputs []string, onLogin func(string) error, s Settings) error {
	dir := filepath.Join(s.TerminalsDir, "account-"+time.Now().Format("20060102-150405"))
	job.step("Creating a new MT5 in %s", dir)
	if err := copyMT5(s.MT5Source, bestServerList(m.Accounts(), "", s.MT5Source), dir); err != nil {
		return fmt.Errorf("copy MT5: %w", err)
	}
	if err := installEAs(m.buildDir(), dir); err != nil {
		return err
	}
	ea := "CopierMaster"
	if role == RoleFollower {
		ea = "CopierFollower"
	}
	if err := writeEAChart(dir, "Default", "chart01.chr", "EURUSD", ea, inputs); err != nil {
		return err
	}
	path := filepath.Join(dir, iniName)
	if err := writeUTF16(path, "[Experts]\nAllowLiveTrading=1\nAllowDllImport=0\nEnabled=1\nAccount=0\nProfile=0\n"); err != nil {
		return err
	}
	if err := Start(dir, path, true); err != nil {
		return err
	}
	time.AfterFunc(iniReadTimeout, func() { os.Remove(path) })

	job.step("MT5 is open. Log in there: File → Open an Account → search your broker → " +
		"Connect with an existing trade account → enter login, password and server → tick Save password → Finish.")
	e := Existing{Dir: dir, DataDir: dir, Profile: "Default"}
	if !waitUntil(func() bool {
		var ok bool
		e.Login, e.Server, ok = loginFromLogs(dir)
		return ok
	}, blankLoginWait) {
		return fmt.Errorf("no login within %v. That MT5 (%s) is still there: log in, then use "+
			"\"An MT5 I already have\" with that folder - or close it and delete the folder", blankLoginWait, dir)
	}
	if _, ok := m.Find(e.Login); ok {
		return fmt.Errorf("account %s is already added - close this new MT5 and delete %s", e.Login, dir)
	}
	job.step("Logged in as %s on %s.", e.Login, e.Server)
	if err := m.saveAccount(Account{Login: e.Login, Server: e.Server, Role: role, Dir: dir}); err != nil {
		return err
	}
	if onLogin != nil {
		if err := onLogin(e.Login); err != nil {
			return err
		}
	}
	job.step("Done - the account appears on the Overview within a few seconds.")
	return nil
}
