package api

import (
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
)

func (a *API) getConfig(w http.ResponseWriter, r *http.Request) {
	login, ok := loginParam(w, r.PathValue("login"), false)
	if !ok {
		return
	}
	c, err := a.st.Config(login)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, c)
}

func (a *API) putConfig(w http.ResponseWriter, r *http.Request) {
	login, ok := loginParam(w, r.PathValue("login"), false)
	if !ok {
		return
	}
	var c store.Config
	if !decodeJSON(w, r, &c) {
		return
	}
	if err := a.st.SaveConfig(login, c); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, c)
}
