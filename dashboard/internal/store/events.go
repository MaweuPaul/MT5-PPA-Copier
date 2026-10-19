package store

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// Event is one line of events\follower_<login>.jsonl.
type Event struct {
	Time      string   `json:"time"` // local "YYYY.MM.DD HH:MM:SS"
	Ms        int64    `json:"ms"`   // Windows uptime ms, shared by all terminals
	Login     int64    `json:"login"`
	Kind      string   `json:"kind"` // open | close | partial | sltp | skip | error | risk | info | config | state | start
	Master    int64    `json:"master"`
	Msg       string   `json:"msg"`
	LatencyMs *float64 `json:"latency_ms,omitempty"`

	// Only on "open": the fill, for slippage against the master.
	Symbol      string  `json:"symbol,omitempty"`
	Side        string  `json:"side,omitempty"`
	Lots        float64 `json:"lots,omitempty"`
	Price       float64 `json:"price,omitempty"`
	MasterPrice float64 `json:"master_price,omitempty"`
	MasterLots  float64 `json:"master_lots,omitempty"`
	Point       float64 `json:"point,omitempty"`
}

// Events returns the newest `limit` events, newest first; login "" = all.
func (s *Store) Events(login string, limit int) []Event {
	name := "follower_*.jsonl"
	if login != "" {
		name = "follower_" + login + ".jsonl"
	}
	files, _ := filepath.Glob(s.path("events", name))
	out := []Event{}
	for _, f := range files {
		out = append(out, readEventLines(f)...)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Time != out[j].Time {
			return out[i].Time > out[j].Time
		}
		return out[i].Ms > out[j].Ms
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func readEventLines(path string) []Event {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []Event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var e Event
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.Time != "" {
			out = append(out, e)
		}
	}
	return out
}
