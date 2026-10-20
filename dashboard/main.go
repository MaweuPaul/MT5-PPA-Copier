// Command dashboard is the local control panel for MT5 MT4 PPA Copier.
//
// It only reads and writes the files the MT5 EAs share in the MetaTrader
// Common Files folder; copying itself never goes through it, so trades keep
// copying while it's closed. It can also create, start and stop the MT5
// installs for each account (package terminals).
package main

import (
	"embed"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/api"
	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
	"github.com/MaweuPaul/trade-copier/dashboard/internal/terminals"
)

//go:embed web
var webFS embed.FS

func main() {
	addr := flag.String("addr", "127.0.0.1:8750", "listen address (loopback only)")
	root := flag.String("root", store.DefaultRoot(), "TradeCopier folder inside MetaTrader Common Files")
	mql5 := flag.String("mql5", findMQL5(), "the repo's MQL5 folder (EA sources, compiled for new accounts)")
	open := flag.Bool("open", true, "open the dashboard in the default browser")
	launch := flag.Bool("launch", true, "start every added account's MT5 that isn't running")
	flag.Parse()

	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		log.Fatalf("bad -addr %q: %v", *addr, err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		log.Fatalf("refusing to listen on %s: the dashboard must only be reachable from this PC", host)
	}

	tm := terminals.New(*root, *mql5)
	tm.RemoveLeftoverInis()
	if *launch {
		tm.StartAll()
	}

	mux := http.NewServeMux()
	api.New(store.New(*root), tm).Register(mux)
	web, _ := fs.Sub(webFS, "web")
	mux.Handle("GET /", http.FileServerFS(web))

	srv := &http.Server{
		Addr:              *addr,
		Handler:           api.Guard(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
	url := "http://" + *addr
	log.Printf("dashboard on %s (files: %s)", url, *root)
	if *open {
		exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	}
	log.Fatal(srv.ListenAndServe())
}

// findMQL5 looks for the repo's MQL5 folder next to (or above) the executable
// and the working directory, so the default works from dashboard\ or the repo root.
func findMQL5() string {
	var starts []string
	if exe, err := os.Executable(); err == nil {
		starts = append(starts, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}
	for _, dir := range starts {
		for i := 0; i < 3; i++ {
			candidate := filepath.Join(dir, "MQL5")
			if _, err := os.Stat(filepath.Join(candidate, "Experts", "TradeCopier")); err == nil {
				return candidate
			}
			dir = filepath.Dir(dir)
		}
	}
	return "MQL5"
}
