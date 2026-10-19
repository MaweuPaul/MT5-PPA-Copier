package store

import (
	"fmt"
	"sort"
	"time"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"
)

// Follower is a follower EA's status (status\follower_<login>.json).
type Follower struct {
	Login         int64   `json:"login"`
	Server        string  `json:"server"`
	MasterID      string  `json:"master_id"`
	State         string  `json:"state"`
	Balance       float64 `json:"balance"`
	Equity        float64 `json:"equity"`
	Multiplier    float64 `json:"multiplier"`
	Paused        bool    `json:"paused"`
	OpenCopies    int     `json:"open_copies"`
	LatencyLastMs float64 `json:"latency_last_ms"`
	LatencyAvgMs  float64 `json:"latency_avg_ms"`
	LatencyMaxMs  float64 `json:"latency_max_ms"`
	UpdatedLocal  string  `json:"updated_local"`
	Settings      Config  `json:"settings"`
	Risk          Risk    `json:"risk"`
	Liveness
}

type Risk struct {
	DailyPnl       float64 `json:"daily_pnl"`
	DailyLossLimit float64 `json:"daily_loss_limit"`
	EquityFloor    float64 `json:"equity_floor"`
	Breached       bool    `json:"breached"`
	Reason         string  `json:"reason"`
}

func (s *Store) statusPath(login string) string {
	return s.path("status", "follower_"+login+".json")
}

func (s *Store) Followers() []Follower {
	out := jsonfile.ReadAll(s.path("status", "follower_*.json"), func(f *Follower, age time.Duration) {
		f.Liveness = liveness(age)
		// "stopped" is the last status an EA writes when it's removed; the file
		// stays behind, so a fresh timestamp alone doesn't mean it's running.
		f.Online = f.Online && f.State != "stopped"
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Login < out[j].Login })
	return out
}

func (s *Store) Follower(login string) (Follower, error) {
	var f Follower
	if _, err := jsonfile.Read(s.statusPath(login), &f); err != nil {
		return f, fmt.Errorf("unknown follower %s", login)
	}
	return f, nil
}
