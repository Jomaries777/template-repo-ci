package app

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// Handler serves every request through Route.
func Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		res := Route(r.Method, r.URL.Path)
		payload, err := json.Marshal(res.Body)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.WriteHeader(res.Status)
		_, _ = w.Write(payload)
	})
}
