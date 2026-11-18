package app

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Export renders StaticRoutes into dir for hosts that only serve files
// (GitHub Pages): "/" becomes index.html and "/health" becomes
// health/index.html, so the same smoke suite passes against the export served
// locally and against the live site. It returns the files it wrote.
func Export(dir string) ([]string, error) {
	var written []string
	for _, path := range StaticRoutes {
		res := Route("GET", path)
		if res.Status != 200 {
			return written, fmt.Errorf("export: GET %s returned %d", path, res.Status)
		}
		payload, err := json.Marshal(res.Body)
		if err != nil {
			return written, err
		}
		target := filepath.Join(dir, strings.Trim(path, "/"), "index.html")
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return written, err
		}
		if err := os.WriteFile(target, payload, 0o644); err != nil {
			return written, err
		}
		written = append(written, target)
	}
	return written, nil
}
