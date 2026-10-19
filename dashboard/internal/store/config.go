package store

import (
	"errors"
	"fmt"
	"strings"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"
)

// Config is a follower's dashboard-controlled settings
// (config\follower_<login>.json). The EA re-reads it live.
type Config struct {
	Enabled      bool    `json:"enabled"`
	Multiplier   float64 `json:"multiplier"`
	MaxLot       float64 `json:"max_lot"`
	RoundUpMin   bool    `json:"round_up_min"`
	CopySLTP     bool    `json:"copy_sltp"`
	SymbolSuffix string  `json:"symbol_suffix"`
	SymbolPrefix string  `json:"symbol_prefix"`
	StripSuffix  string  `json:"strip_suffix"`
	SymbolMap    string  `json:"symbol_map"`
}

// Limits shared with the EA (CopierFollower.mq5 ApplyConfig) and the UI.
const (
	MinMultiplier = 0.01
	MaxMultiplier = 100.0
	MaxMaxLot     = 1000
	maxAffixLen   = 16
	maxMapLen     = 2000
)

func (c Config) Validate() error {
	switch {
	case c.Multiplier < MinMultiplier || c.Multiplier > MaxMultiplier:
		return fmt.Errorf("multiplier must be between %g and %g", MinMultiplier, MaxMultiplier)
	case c.MaxLot < 0 || c.MaxLot > MaxMaxLot:
		return fmt.Errorf("max lot must be between 0 (no limit) and %d", MaxMaxLot)
	case len(c.SymbolSuffix) > maxAffixLen || len(c.SymbolPrefix) > maxAffixLen || len(c.StripSuffix) > maxAffixLen:
		return fmt.Errorf("symbol prefix/suffix must be %d characters or fewer", maxAffixLen)
	case len(c.SymbolMap) > maxMapLen:
		return errors.New("symbol map is too long")
	}
	return validateSymbolMap(c.SymbolMap)
}

// validateSymbolMap checks "MASTER=FOLLOWER;MASTER=FOLLOWER".
func validateSymbolMap(spec string) error {
	for _, pair := range strings.Split(spec, ";") {
		if strings.TrimSpace(pair) == "" {
			continue
		}
		from, to, ok := strings.Cut(pair, "=")
		if !ok || strings.TrimSpace(from) == "" || strings.TrimSpace(to) == "" || strings.Contains(to, "=") {
			return fmt.Errorf("symbol map entry %q must look like MASTER=FOLLOWER", pair)
		}
	}
	return nil
}

func (s *Store) configPath(login string) string {
	return s.path("config", "follower_"+login+".json")
}

// Config returns the saved config, or the follower's live settings from its
// status file if nothing has been saved from the dashboard yet.
func (s *Store) Config(login string) (Config, error) {
	var c Config
	if _, err := jsonfile.Read(s.configPath(login), &c); err == nil {
		return c, nil
	}
	f, err := s.Follower(login)
	return f.Settings, err
}

func (s *Store) SaveConfig(login string, c Config) error {
	if err := c.Validate(); err != nil {
		return err
	}
	return jsonfile.Write(s.configPath(login), c)
}
