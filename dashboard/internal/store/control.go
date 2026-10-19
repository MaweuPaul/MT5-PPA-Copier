package store

import "github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"

// Control holds switches that apply to every follower (control.json).
type Control struct {
	Paused bool `json:"paused"`
}

func (s *Store) Control() Control {
	var c Control
	jsonfile.Read(s.path("control.json"), &c) // missing file = defaults
	return c
}

func (s *Store) SetPaused(paused bool) error {
	return jsonfile.Write(s.path("control.json"), Control{Paused: paused})
}
