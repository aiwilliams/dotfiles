# Worktree & Database Management

Local development uses native PostgreSQL 18 with pgvector (not Docker). Two CLI tools in `~/dotfiles/bin/` manage worktrees and databases.

## `wt` — Git Worktree Manager

Creates worktrees as sibling directories named `<repo>-<branch>`. Automatically clones databases, wires `.env`, and runs project setup.

```
wt create <branch>         # Create worktree + clone DBs + wire .env + run setup
wt remove <branch>         # Remove worktree + drop DBs + delete merged branch
wt list                    # List all worktrees with branch, dirty status, commit
wt switch                  # Interactive fzf worktree switcher
```

`wt create` does the full flow: `git worktree add`, clones DBs from main, copies `.env` from the main worktree, replaces `POSTGRES_*` vars with per-branch values, and runs `scripts/setup.sh`.

## `db-worktree` — Database Manager

Lower-level tool for managing per-worktree PostgreSQL databases directly.

```
db-worktree create <branch>           # Create empty DBs + user
db-worktree clone <branch> [source]   # Clone from source (default: main)
db-worktree drop <branch>             # Drop DBs + user
db-worktree list                      # List all worktree databases
db-worktree status <branch>           # Show user, DB sizes, extensions
db-worktree env <branch>              # Print .env vars
db-worktree init-main                 # Create main branch DBs
```

## Database Naming

Branch names are sanitized: lowercased, non-alphanumeric replaced with `_`, collapsed, truncated to 50 chars. Example: `feature/cool-thing` becomes `feature_cool_thing`.

Each branch gets: `platform_<sanitized>`, `vector_<sanitized>`, and a user named `<sanitized>` (password = username). Both databases use port 5432 (single PG instance).

## Wiring into .env

The `POSTGRES_*` and `POSTGRES_VECTOR_*` variables in `apps/platform/.env` match `.env.example` format. `wt create` handles this automatically. For manual use, run `db-worktree env <branch>`.

## Library

All functions live in `~/dotfiles/lib/postgres.sh`. Scripts source this file; it is not executed directly.
