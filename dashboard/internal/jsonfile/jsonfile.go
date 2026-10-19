// Package jsonfile reads and writes JSON files shared with the MT5 EAs.
//
// The EAs rewrite their files in place, so a read can catch one half-written;
// Read retries briefly. Write goes through a temp file + rename so an EA
// never sees a partial file from us.
package jsonfile

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

const (
	readAttempts   = 5
	renameAttempts = 20
	retryDelay     = 5 * time.Millisecond
)

var utf8BOM = []byte("\xef\xbb\xbf")

// Read decodes path into v and returns how long ago the file was written.
func Read(path string, v any) (age time.Duration, err error) {
	for attempt := 0; attempt < readAttempts; attempt++ {
		var info os.FileInfo
		if info, err = os.Stat(path); err != nil {
			return 0, err // missing: no point retrying
		}
		var data []byte
		if data, err = os.ReadFile(path); err == nil {
			if err = json.Unmarshal(bytes.TrimPrefix(data, utf8BOM), v); err == nil {
				return time.Since(info.ModTime()), nil
			}
		}
		time.Sleep(retryDelay)
	}
	return 0, err
}

// Write encodes v to path atomically. The rename can briefly fail while an
// EA has the target open for reading, so it is retried.
func Write(path string, v any) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // the EAs' JSON reader only understands \" and \\ escapes
	if err := enc.Encode(v); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, bytes.TrimRight(buf.Bytes(), "\n"), 0o644); err != nil {
		return err
	}
	var err error
	for attempt := 0; attempt < renameAttempts; attempt++ {
		if err = os.Rename(tmp, path); err == nil {
			return nil
		}
		time.Sleep(2 * retryDelay)
	}
	os.Remove(tmp)
	return err
}

// ReadAll decodes every file matching pattern, skipping unreadable ones,
// and reports each file's age to the caller.
func ReadAll[T any](pattern string, each func(item *T, age time.Duration)) []T {
	files, _ := filepath.Glob(pattern)
	out := make([]T, 0, len(files))
	for _, f := range files {
		var item T
		age, err := Read(f, &item)
		if err != nil {
			continue
		}
		if each != nil {
			each(&item, age)
		}
		out = append(out, item)
	}
	return out
}
