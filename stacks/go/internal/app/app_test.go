package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func get(t *testing.T, srv *httptest.Server, method, path string) (int, string, map[string]string) {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body map[string]string
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("%s %s: body is not JSON: %v", method, path, err)
	}
	return res.StatusCode, res.Header.Get("Content-Type"), body
}

func TestRootReturnsHello(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	status, ctype, body := get(t, srv, "GET", "/")
	if status != 200 || ctype != "application/json; charset=utf-8" || body["message"] != "hello" {
		t.Fatalf("got %d %q %v", status, ctype, body)
	}
}

func TestRootKeepsReturning200(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	for i := 0; i < 3; i++ {
		if status, _, _ := get(t, srv, "GET", "/"); status != 200 {
			t.Fatalf("call %d: got %d", i+1, status)
		}
	}
}

func TestHealthVersion(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	t.Setenv("APP_VERSION", "")
	if _, _, body := get(t, srv, "GET", "/health"); body["status"] != "ok" || body["version"] != "dev" {
		t.Fatalf("default: got %v", body)
	}
	t.Setenv("APP_VERSION", "1.2.3-sha")
	if _, _, body := get(t, srv, "GET", "/health"); body["version"] != "1.2.3-sha" {
		t.Fatalf("APP_VERSION: got %v", body)
	}
}

// Cloud Run reserves some paths ending in "z": the health route is /health.
func TestHealthzIsNotServed(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	if status, _, _ := get(t, srv, "GET", "/healthz"); status != 404 {
		t.Fatalf("got %d", status)
	}
}

func TestUnknownRouteAndMethodAre404JSON(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	if status, _, body := get(t, srv, "GET", "/missing"); status != 404 || body["error"] != "not found" {
		t.Fatalf("got %d %v", status, body)
	}
	if status, _, _ := get(t, srv, "POST", "/"); status != 404 {
		t.Fatalf("POST /: got %d", status)
	}
}

func TestExportWritesEveryStaticRoute(t *testing.T) {
	dir := t.TempDir()
	files, err := Export(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 {
		t.Fatalf("wrote %v", files)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "health", "index.html"))
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]string
	if err := json.Unmarshal(raw, &body); err != nil || body["status"] != "ok" {
		t.Fatalf("health export: %s (%v)", raw, err)
	}
}
