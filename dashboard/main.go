// Command dashboard is the local control panel for the trade copier.
//
// It only reads and writes the files the MT5 EAs share in the MetaTrader
// Common Files folder; copying itself never goes through it, so trades keep
// copying while it's closed.
package main

import (
	"embed"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os/exec"
	"time"

	"github.com/MaweuPaul/trade-copier/dashboard/internal/api"
	"github.com/MaweuPaul/trade-copier/dashboard/internal/store"
)

//go:embed web
var webFS embed.FS

func main() {
	addr := flag.String("addr", "127.0.0.1:8750", "listen address (loopback only)")
	root := flag.String("root", store.DefaultRoot(), "TradeCopier folder inside MetaTrader Common Files")
	open := flag.Bool("open", true, "open the dashboard in the default browser")
	flag.Parse()

	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		log.Fatalf("bad -addr %q: %v", *addr, err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		log.Fatalf("refusing to listen on %s: the dashboard must only be reachable from this PC", host)
	}

	mux := http.NewServeMux()
	api.New(store.New(*root)).Register(mux)
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
