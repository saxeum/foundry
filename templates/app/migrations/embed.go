// Package migrations embeds the SQL applied by the migration Job. The files are
// in the image, so the binary that runs them is the binary that contains them.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
