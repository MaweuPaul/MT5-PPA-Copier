package api

import (
	"net"
	"net/http"
)

var loopbackHosts = map[string]bool{"127.0.0.1": true, "localhost": true, "::1": true}

// Guard protects a localhost-only server from other websites open in the
// same browser:
//   - Host must be loopback, which blocks DNS-rebinding attacks.
//   - Requests that change something must carry X-Requested-With. A custom
//     header forces a CORS preflight, which is never approved, so another
//     site can't send one (no CSRF).
func Guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		if !loopbackHosts[host] {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead &&
			r.Header.Get("X-Requested-With") != "tradecopier" {
			http.Error(w, "missing X-Requested-With header", http.StatusForbidden)
			return
		}
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
