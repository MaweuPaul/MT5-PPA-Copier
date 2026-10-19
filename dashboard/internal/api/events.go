package api

import (
	"net/http"
	"strconv"
)

const (
	defaultEventLimit = 200
	maxEventLimit     = 1000
)

func (a *API) events(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	login, ok := loginParam(w, q.Get("login"), true)
	if !ok {
		return
	}
	limit, err := strconv.Atoi(q.Get("limit"))
	if err != nil || limit <= 0 || limit > maxEventLimit {
		limit = defaultEventLimit
	}
	writeJSON(w, http.StatusOK, a.st.Events(login, limit))
}
