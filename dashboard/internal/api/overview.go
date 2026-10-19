package api

import "net/http"

// overview is everything the main screen needs, in one poll.
func (a *API) overview(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"masters":   a.st.Masters(),
		"followers": a.st.Followers(),
		"paused":    a.st.Control().Paused,
	})
}
