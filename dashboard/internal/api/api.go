// Package api is the dashboard's JSON API over the shared EA files.
package api

import (
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
	"github.com/MaweuPaul/trade-copier/dashboard/internal/terminals"
)

type API struct {
	st *store.Store
	tm *terminals.Manager
}

func New(st *store.Store, tm *terminals.Manager) *API { return &API{st: st, tm: tm} }

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/overview", a.overview)
	mux.HandleFunc("GET /api/followers/{login}/config", a.getConfig)
	mux.HandleFunc("PUT /api/followers/{login}/config", a.putConfig)
	mux.HandleFunc("POST /api/pause", a.setPaused(true))
	mux.HandleFunc("POST /api/resume", a.setPaused(false))
	mux.HandleFunc("GET /api/events", a.events)
	mux.HandleFunc("GET /api/templates", a.listTemplates)
	mux.HandleFunc("PUT /api/templates/{name}", a.putTemplate)
	mux.HandleFunc("DELETE /api/templates/{name}", a.deleteTemplate)

	mux.HandleFunc("GET /api/accounts", a.listAccounts)
	mux.HandleFunc("POST /api/accounts", a.addAccount)
	mux.HandleFunc("GET /api/accounts/jobs/{id}", a.addJob)
	mux.HandleFunc("POST /api/accounts/start-all", a.startAll)
	mux.HandleFunc("POST /api/accounts/{login}/start", a.accountAction("start"))
	mux.HandleFunc("POST /api/accounts/{login}/stop", a.accountAction("stop"))
	mux.HandleFunc("DELETE /api/accounts/{login}", a.accountAction("remove"))
	mux.HandleFunc("PUT /api/setup", a.saveSetup)
}
