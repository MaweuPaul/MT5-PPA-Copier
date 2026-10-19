package store

import (
	"errors"
	"fmt"
	"regexp"
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

	// Risk (0 / "" = off)
	DailyLossLimit float64 `json:"daily_loss_limit"`
	EquityFloor    float64 `json:"equity_floor"`
	CloseOnLimit   bool    `json:"close_on_limit"`
	MaxOpenTrades  int     `json:"max_open_trades"`
	MaxTotalLots   float64 `json:"max_total_lots"`
	TradeStart     string  `json:"trade_start"` // "HH:MM" local; both empty = always
	TradeEnd       string  `json:"trade_end"`
	NewsMinutes    int     `json:"news_minutes"`

	// Delay before copying: fixed + random 0..jitter
	DelayMs       int  `json:"delay_ms"`
	DelayJitterMs int  `json:"delay_jitter_ms"`
	DelayCloses   bool `json:"delay_closes"`
}

// Limits shared with the EA (CopierFollower.mq5 ApplyConfig) and the UI.
const (
	MinMultiplier = 0.01
	MaxMultiplier = 100.0
	MaxMaxLot     = 1000
	maxAffixLen   = 16
	maxMapLen     = 2000
	maxDelayMs    = 60000
	maxJitterMs   = 30000
	maxNewsMin    = 240
)

var hhmmRe = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)

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
	case c.DailyLossLimit < 0 || c.EquityFloor < 0 || c.MaxOpenTrades < 0 || c.MaxTotalLots < 0:
		return errors.New("risk limits can't be negative")
	case c.NewsMinutes < 0 || c.NewsMinutes > maxNewsMin:
		return fmt.Errorf("news window must be 0-%d minutes", maxNewsMin)
	case c.DelayMs < 0 || c.DelayMs > maxDelayMs || c.DelayJitterMs < 0 || c.DelayJitterMs > maxJitterMs:
		return fmt.Errorf("delay must be 0-%d ms and random extra 0-%d ms", maxDelayMs, maxJitterMs)
	case (c.TradeStart == "") != (c.TradeEnd == ""),
		c.TradeStart != "" && (!hhmmRe.MatchString(c.TradeStart) || !hhmmRe.MatchString(c.TradeEnd)):
		return errors.New("trading hours must both be HH:MM (24h), or both empty")
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
