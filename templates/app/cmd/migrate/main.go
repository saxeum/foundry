// Command migrate applies the embedded migrations. It ships in the app image so
// the migration Job runs the same binary as the Deployment.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/saxeum/__APP_NAME__/migrations"
	"github.com/saxeum/foundry/go/migrate"
)

func main() {
	status := flag.Bool("status", false, "print applied, pending and changed migrations without writing anything")
	flag.Parse()

	if err := run(*status); err != nil {
		fmt.Fprintf(os.Stderr, "migrate: %v\n", err)
		os.Exit(1)
	}
}

func run(status bool) error {
	dsn := os.Getenv("DATABASE_URL_OWNER")
	if dsn == "" {
		return fmt.Errorf("DATABASE_URL_OWNER is not set: migrations run as the owner, not as the application role")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	all, err := migrate.Discover(migrations.FS, ".")
	if err != nil {
		return err
	}
	if len(all) == 0 {
		return fmt.Errorf("no migrations were embedded; the build is broken")
	}

	// The owner DSN gets the migrator's own pool: the app's statement_timeout is
	// for request-sized work, not for an ALTER TABLE.
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer pool.Close()

	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		return fmt.Errorf("ping database: %w", err)
	}

	if status {
		report, err := migrate.Status(ctx, pool, all)
		if err != nil {
			return err
		}
		printStatus(report)
		return nil
	}

	report, err := migrate.Apply(ctx, pool, all)
	if err != nil {
		return err
	}
	printApplied(report, len(all))
	return nil
}

func printStatus(r migrate.Report) {
	for _, m := range r.Applied {
		fmt.Printf("applied  %s\n", m.Name)
	}
	for _, m := range r.Pending {
		fmt.Printf("pending  %s\n", m.Name)
	}
	for _, m := range r.Changed {
		fmt.Printf("changed  %s\n", m.Name)
	}
	fmt.Printf("%d applied, %d pending, %d changed\n", len(r.Applied), len(r.Pending), len(r.Changed))
}

func printApplied(r migrate.Report, total int) {
	for _, m := range r.Backfilled {
		fmt.Printf("recorded checksum for %s (applied before checksums existed)\n", m.Name)
	}
	if len(r.Applied) == 0 {
		fmt.Printf("nothing to apply; %d migration(s) already recorded\n", total)
		return
	}
	for _, m := range r.Applied {
		fmt.Printf("applied %s\n", m.Name)
	}
}
