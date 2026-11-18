// Command export renders the GET routes to static files: export <dir>.
package main

import (
	"fmt"
	"os"

	"example.com/app/internal/app"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: export <output dir>")
		os.Exit(2)
	}
	files, err := app.Export(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, f := range files {
		fmt.Println(f)
	}
}
