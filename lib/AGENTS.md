# Per-Worktree PostgreSQL Databases

Local development uses native PostgreSQL 18 with pgvector (not Docker). Each git worktree gets isolated databases and a dedicated user via `db-worktree` (`~/dotfiles/bin/db-worktree`).

## Database Naming

Branch names are sanitized: lowercased, non-alphanumeric replaced with `_`, collapsed, truncated to 50 chars. Example: `feature/cool-thing` becomes `feature_cool_thing`.

Each branch gets: `platform_<sanitized>`, `vector_<sanitized>`, and a user named `<sanitized>` (password = username).

## Commands

```
db-worktree create <branch>           # Create empty DBs + user
db-worktree clone <branch> [source]   # Clone from source (default: main)
db-worktree drop <branch>             # Drop DBs + user
db-worktree list                      # List all worktree databases
db-worktree status <branch>           # Show user, DB sizes, extensions
db-worktree env <branch>              # Print .env vars
db-worktree init-main                 # Create main branch DBs
```

## Wiring into .env

Run `db-worktree env <branch>` and copy the output into `apps/platform/.env`. The output matches the `POSTGRES_*` and `POSTGRES_VECTOR_*` variables from `.env.example`. Both databases use port 5432 (single PG instance), unlike the old Docker setup which had vector on 5434.

## Library

All functions live in `~/dotfiles/lib/postgres.sh`. Scripts source this file; it is not executed directly.
