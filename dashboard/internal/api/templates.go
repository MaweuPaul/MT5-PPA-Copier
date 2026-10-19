package api

import (
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
)

func (a *API) listTemplates(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.st.Templates())
}

func (a *API) putTemplate(w http.ResponseWriter, r *http.Request) {
	var c store.Config
	if !decodeJSON(w, r, &c) {
		return
	}
	if err := a.st.SaveTemplate(r.PathValue("name"), c); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, c)
}

func (a *API) deleteTemplate(w http.ResponseWriter, r *http.Request) {
	if err := a.st.DeleteTemplate(r.PathValue("name")); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
