package api

import (
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
	"github.com/MaweuPaul/trade-copier/dashboard/internal/terminals"
)

func (a *API) listAccounts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"accounts":  a.tm.Statuses(),
		"settings":  a.tm.Settings(),
		"autostart": terminals.AutostartEnabled(),
	})
}

func (a *API) addAccount(w http.ResponseWriter, r *http.Request) {
	var req terminals.AddRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	// A follower's lot size, suffix and delays become its dashboard config,
	// checked before anything is created and picked up when its EA starts.
	cfg, _, ok := copyingForm{req.Role, req.MasterID, req.Multiplier, req.Suffix,
		req.DelayMs, req.DelayJitterMs, req.CloseDelayMs, req.CloseDelayJitterMs}.followerConfig(w)
	if !ok {
		return
	}
	id, err := a.tm.Add(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := a.saveFollower(req.Role, req.Login, cfg); err != nil {
		writeError(w, http.StatusInternalServerError, "account is being added, but saving its settings failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"job": id})
}

// copyingForm is the "Copying" part of the add forms (followers only).
type copyingForm struct {
	Role               string  `json:"role"`
	MasterID           string  `json:"master_id"`
	Multiplier         float64 `json:"multiplier"`
	Suffix             string  `json:"symbol_suffix"`
	DelayMs            int     `json:"delay_ms"`
	DelayJitterMs      int     `json:"delay_jitter_ms"`
	CloseDelayMs       int     `json:"close_delay_ms"`
	CloseDelayJitterMs int     `json:"close_delay_jitter_ms"`
}

// followerConfig validates the copying fields and returns the config to save
// and the EA inputs for the chart. ok=false means a 400 was written.
func (f copyingForm) followerConfig(w http.ResponseWriter) (cfg store.Config, inputs []string, ok bool) {
	cfg = store.DefaultConfig()
	if f.Role != terminals.RoleFollower {
		return cfg, []string{}, true
	}
	if !store.ValidLogin(f.MasterID) {
		writeError(w, http.StatusBadRequest, "enter the main account's login")
		return cfg, nil, false
	}
	cfg.Multiplier, cfg.SymbolSuffix = f.Multiplier, f.Suffix
	cfg.DelayMs, cfg.DelayJitterMs = f.DelayMs, f.DelayJitterMs
	cfg.CloseDelayMs, cfg.CloseDelayJitterMs = f.CloseDelayMs, f.CloseDelayJitterMs
	if err := cfg.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return cfg, nil, false
	}
	return cfg, []string{"MasterId=" + f.MasterID}, true
}

// saveFollower stores a new follower's settings once its login is known.
func (a *API) saveFollower(role, login string, cfg store.Config) error {
	if role != terminals.RoleFollower {
		return nil
	}
	return a.st.SaveConfig(login, cfg)
}

// attachAccount adds the copier to an MT5 the user already has.
func (a *API) attachAccount(w http.ResponseWriter, r *http.Request) {
	var req struct {
		copyingForm
		Folder string `json:"folder"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	cfg, inputs, ok := req.followerConfig(w)
	if !ok {
		return
	}
	id, found, err := a.tm.Attach(terminals.AttachRequest{Role: req.Role, Folder: req.Folder}, func(string) []string { return inputs })
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := a.saveFollower(req.Role, found.Login, cfg); err != nil {
		writeError(w, http.StatusInternalServerError, "saving its settings failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"job": id, "login": found.Login, "server": found.Server})
}

// openBlank opens a fresh MT5 for the user to log in to; setup finishes on login.
func (a *API) openBlank(w http.ResponseWriter, r *http.Request) {
	var req copyingForm
	if !decodeJSON(w, r, &req) {
		return
	}
	cfg, inputs, ok := req.followerConfig(w)
	if !ok {
		return
	}
	id, err := a.tm.OpenBlank(req.Role, inputs, func(login string) error { return a.saveFollower(req.Role, login, cfg) })
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"job": id})
}

func (a *API) addJob(w http.ResponseWriter, r *http.Request) {
	job, ok := a.tm.Job(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "unknown job")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

// startAll launches every added account's MT5 that isn't already running.
func (a *API) startAll(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]int{"started": a.tm.StartAll()})
}

// accountAction runs start / stop / remove on a registered account.
func (a *API) accountAction(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		login, ok := loginParam(w, r.PathValue("login"), false)
		if !ok {
			return
		}
		acc, ok := a.tm.Find(login)
		if !ok && action == "remove" {
			// Not registered (e.g. a copier that once ran in an MT5 set up by
			// hand): just forget its files so it leaves the Overview.
			a.st.Forget(login)
			writeJSON(w, http.StatusOK, map[string]string{"dir": ""})
			return
		}
		if !ok {
			writeError(w, http.StatusNotFound, "unknown account")
			return
		}
		dir := acc.Dir
		var err error
		switch action {
		case "start":
			err = acc.Start()
		case "stop":
			err = terminals.Stop(dir)
		case "remove":
			_, err = a.tm.Remove(login, r.URL.Query().Get("delete_folder") == "1")
			if _, still := a.tm.Find(login); !still {
				a.st.Forget(login) // unregistered, even if its folder couldn't be deleted
			}
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"dir": dir})
	}
}

func (a *API) saveSetup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		terminals.Settings
		Autostart bool `json:"autostart"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	if err := a.tm.SaveSettings(body.Settings); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := terminals.SetAutostart(body.Autostart); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, body)
}
