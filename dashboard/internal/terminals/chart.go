package terminals

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// chart.chr is an untouched MT5 default chart (UTF-16LE), used as a template.
//
//go:embed chart.chr
var chartTemplate []byte

var symbolLineRe = regexp.MustCompile(`(?m)^symbol=.*$`)

// writeEAChart writes a chart of `symbol` with the copier EA attached into
// an MT5 profile (<dataDir>/MQL5/Profiles/Charts/<profile>/<file>). MT5
// reopens profile charts on every start, so the EA stays attached across
// restarts - unlike a /config [StartUp] chart, which MT5 doesn't keep.
// inputs are "Name=value" EA inputs.
func writeEAChart(dataDir, profile, file, symbol, ea string, inputs []string) error {
	chart := symbolLineRe.ReplaceAllString(decodeUTF16(chartTemplate), "symbol="+symbol)
	end := strings.LastIndex(chart, "</chart>")
	if end < 0 {
		return fmt.Errorf("chart template is missing </chart>")
	}
	expert := fmt.Sprintf("<expert>\nname=%s\npath=Experts\\TradeCopier\\%s.ex5\nexpertmode=1\n<inputs>\n%s\n</inputs>\n</expert>\n",
		ea, ea, strings.Join(inputs, "\n"))
	chart = chart[:end] + strings.ReplaceAll(expert, "\n", "\r\n") + chart[end:]
	path := filepath.Join(dataDir, "MQL5", "Profiles", "Charts", profile, file)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return writeUTF16(path, strings.ReplaceAll(chart, "\r\n", "\n")) // writeUTF16 restores CRLF
}
