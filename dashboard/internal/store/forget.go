package store

import "os"

// Forget deletes the shared files of a removed account, so it no longer shows
// on the Overview and an old master isn't mistaken for the current one. The
// activity log (events\follower_<login>.jsonl) is kept as history.
func (s *Store) Forget(login string) {
	for _, p := range []string{
		s.statusPath(login),
		s.configPath(login),
		s.path("state", "links_"+login+".csv"),
		s.path("master_" + login + ".json"),
	} {
		os.Remove(p)
	}
}
