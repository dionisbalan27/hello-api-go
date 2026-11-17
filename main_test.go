package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHello(t *testing.T) {
	rec := httptest.NewRecorder()
	newRouter().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var body helloResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Message != "Hello World" {
		t.Fatalf("message = %q", body.Message)
	}
}

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	newRouter().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestUnknownPath(t *testing.T) {
	rec := httptest.NewRecorder()
	newRouter().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}
