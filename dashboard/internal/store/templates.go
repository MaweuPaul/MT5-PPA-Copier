package store

import (
	"errors"
	"regexp"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/jsonfile"
)

// Templates are named follower settings presets (templates.json), used only
// by the dashboard: applying one just saves it as a follower's config.
type Templates map[string]Config

var templateNameRe = regexp.MustCompile(`^[\w .\-]{1,40}$`)

func (s *Store) Templates() Templates {
	t := Templates{}
	jsonfile.Read(s.path("templates.json"), &t) // missing file = none
	return t
}

func (s *Store) SaveTemplate(name string, c Config) error {
	if !templateNameRe.MatchString(name) {
		return errors.New("template name: 1-40 letters, digits, spaces, . _ -")
	}
	if err := c.Validate(); err != nil {
		return err
	}
	t := s.Templates()
	t[name] = c
	return jsonfile.Write(s.path("templates.json"), t)
}

func (s *Store) DeleteTemplate(name string) error {
	t := s.Templates()
	delete(t, name)
	return jsonfile.Write(s.path("templates.json"), t)
}
