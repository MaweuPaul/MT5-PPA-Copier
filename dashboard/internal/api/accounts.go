package api

import (
	"net/http"

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
	id, err := a.tm.Add(req)
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

// accountAction runs start / stop / remove on a registered account.
func (a *API) accountAction(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		login, ok := loginParam(w, r.PathValue("login"), false)
		if !ok {
			return
		}
		var dir string
		for _, acc := range a.tm.Accounts() {
			if acc.Login == login {
				dir = acc.Dir
			}
		}
		if dir == "" {
			writeError(w, http.StatusNotFound, "unknown account")
			return
		}
		var err error
		switch action {
		case "start":
			err = terminals.Start(dir, "")
		case "stop":
			err = terminals.Stop(dir)
		case "remove":
			_, err = a.tm.Remove(login)
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
