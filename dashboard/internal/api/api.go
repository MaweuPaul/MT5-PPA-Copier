// Package api is the dashboard's JSON API over the shared EA files.
package api

import (
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
)

type API struct{ st *store.Store }

func New(st *store.Store) *API { return &API{st: st} }

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
}
