package store

import (
	"sort"
	"time"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"
)

type Position struct {
	Ticket   int64   `json:"ticket"`
	Symbol   string  `json:"symbol"`
	Type     string  `json:"type"`
	Volume   float64 `json:"volume"`
	Contract float64 `json:"contract"`
	Price    float64 `json:"price"`
	SL       float64 `json:"sl"`
	TP       float64 `json:"tp"`
	Magic    int64   `json:"magic"`
	TimeMsc  int64   `json:"time_msc"`
}

// Master is a master EA's snapshot (master_<login>.json).
type Master struct {
	MasterID  string     `json:"master_id"`
	Server    string     `json:"server"`
	Balance   float64    `json:"balance"`
	Equity    float64    `json:"equity"`
	Positions []Position `json:"positions"`
	Liveness
}

func (s *Store) Masters() []Master {
	out := jsonfile.ReadAll(s.path("master_*.json"), func(m *Master, age time.Duration) {
		m.Liveness = liveness(age)
		if m.Positions == nil {
			m.Positions = []Position{}
		}
	})
	sort.Slice(out, func(i, j int) bool { return out[i].MasterID < out[j].MasterID })
	return out
}
