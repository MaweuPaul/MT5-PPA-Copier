package api

import (
	"encoding/json"
	"net/http"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// loginParam returns a validated account login from the path or query
// (login "" is allowed when optional). It writes the 400 itself on failure.
func loginParam(w http.ResponseWriter, login string, optional bool) (string, bool) {
	if (optional && login == "") || store.ValidLogin(login) {
		return login, true
	}
	writeError(w, http.StatusBadRequest, "invalid login")
	return "", false
}

// decodeJSON reads a small JSON body strictly (unknown fields are errors).
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return false
	}
	return true
}
