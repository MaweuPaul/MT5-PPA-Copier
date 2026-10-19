// Package store gives typed access to the files the MT5 EAs share in the
// MetaTrader Common Files folder. File formats: docs/snapshot-format.md.
package store

import (
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// A file not rewritten for this long means its writer (an EA) isn't running.
const staleAfter = 5 * time.Second

var loginRe = regexp.MustCompile(`^[0-9]{1,20}$`)

// ValidLogin guards every path built from user input against traversal.
func ValidLogin(login string) bool { return loginRe.MatchString(login) }

// DefaultRoot is %APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier.
func DefaultRoot() string {
	return filepath.Join(os.Getenv("APPDATA"), "MetaQuotes", "Terminal", "Common", "Files", "TradeCopier")
}

type Store struct{ root string }

func New(root string) *Store { return &Store{root: root} }

func (s *Store) path(parts ...string) string {
	return filepath.Join(append([]string{s.root}, parts...)...)
}

// Liveness is embedded in anything an EA rewrites periodically.
type Liveness struct {
	AgeMs  int64 `json:"age_ms"`
	Online bool  `json:"online"`
}

func liveness(age time.Duration) Liveness {
	return Liveness{AgeMs: age.Milliseconds(), Online: age < staleAfter}
}
