package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

type helloResponse struct {
	Message     string    `json:"message"`
	Service     string    `json:"service"`
	Environment string    `json:"environment"`
	Time        time.Time `json:"time"`
}

func newRouter() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", helloHandler)
	mux.HandleFunc("GET /health", healthHandler)
	return mux
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, helloResponse{
		Message:     "Hello World",
		Service:     "hello-api-go",
		Environment: env("APP_ENV", "local"),
		Time:        time.Now().UTC(),
	})
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "OK"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	addr := ":" + env("PORT", "3000")
	log.Printf("hello-api-go listening on %s", addr)
	if err := http.ListenAndServe(addr, newRouter()); err != nil {
		log.Fatal(err)
	}
}
