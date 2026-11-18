// Package app holds the service's routes as one pure function, shared by the
// HTTP server and the static export (`make build-static`), so both always
// answer the same.
package app

import "os"

// Response is a status code and a JSON-serialisable body.
type Response struct {
	Status int
	Body   map[string]string
}

// Route returns the response for a request. It never panics.
func Route(method, path string) Response {
	switch {
	case method == "GET" && path == "/":
		return Response{200, map[string]string{"message": "hello"}}
	// Not /healthz: Cloud Run reserves some paths that end in "z".
	case method == "GET" && path == "/health":
		version := os.Getenv("APP_VERSION")
		if version == "" {
			version = "dev"
		}
		return Response{200, map[string]string{"status": "ok", "version": version}}
	default:
		return Response{404, map[string]string{"error": "not found"}}
	}
}

// StaticRoutes are the GET routes `make build-static` renders to files.
var StaticRoutes = []string{"/", "/health"}
