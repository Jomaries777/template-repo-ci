//go:build acceptance

// Package acceptance checks a running service at BASE_URL. `make smoke` runs
// only the tests whose names contain ProdSafe (read-only, safe against
// production). Paths are relative ("health", not "/health"), so the suite
// also works when the site lives under a sub-path, like GitHub Pages'
// https://<owner>.github.io/<repo>/.
package acceptance

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func fetch(t *testing.T, rel string) (int, map[string]string) {
	t.Helper()
	base := os.Getenv("BASE_URL")
	if base == "" {
		base = "http://localhost:8080"
	}
	baseURL, err := url.Parse(strings.TrimRight(base, "/") + "/")
	if err != nil {
		t.Fatal(err)
	}
	target := baseURL.ResolveReference(&url.URL{Path: rel})
	client := &http.Client{Timeout: 10 * time.Second}
	res, err := client.Get(target.String())
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body map[string]string
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("GET %s: body is not JSON: %v", target, err)
	}
	return res.StatusCode, body
}

func TestProdSafeHealthReturnsOK(t *testing.T) {
	status, body := fetch(t, "health")
	if status != 200 || body["status"] != "ok" || body["version"] == "" {
		t.Fatalf("got %d %v", status, body)
	}
}

func TestProdSafeRootReturnsHello(t *testing.T) {
	status, body := fetch(t, "")
	if status != 200 || body["message"] != "hello" {
		t.Fatalf("got %d %v", status, body)
	}
}

func TestUnknownReturns404JSON(t *testing.T) {
	status, body := fetch(t, "unknown")
	if status != 404 || body["error"] != "not found" {
		t.Fatalf("got %d %v", status, body)
	}
}
