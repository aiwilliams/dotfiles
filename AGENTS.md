# Shell Scripts

All bash scripts must be compatible with **Bash 3.2** (macOS default). Key constraints:

- Empty arrays with `set -u`: `"${arr[@]}"` is an unbound variable error. Guard with `[[ ${#arr[@]} -gt 0 ]]` before expanding.
- No associative arrays (`declare -A`).
- No `readarray`/`mapfile`. Use `while read` loops instead.
- No `${var,,}` / `${var^^}` case conversion. Use `tr` instead.
- No `grep -P` (Perl regex). Use `sed -n 's/…/\1/p'` for extraction instead of `grep -oP` with `\K`.
- No `|&` (pipe stderr). Use `2>&1 |` instead.

# Worktree & Database Management

Local development uses native PostgreSQL 18 with pgvector (not Docker). Two CLI tools in `~/dotfiles/bin/` manage worktrees and databases. Run each command with `--help` or no arguments to see available subcommands and usage.

## `wt` — Git Worktree Manager

Creates worktrees as sibling directories with auto-numbered IDs. Automatically clones databases, wires `.env`, and runs project setup. Run `wt help` for full documentation.

## `pg` — PostgreSQL Query Runner

Execute SQL against project databases using connection info from `.env` files. Auto-discovers `.env` in the current directory or `apps/platform/.env` from the git root. Use `-d vector` for the vector database. Run `pg -h` for full usage.

## `db-worktree` — Database Manager

Lower-level tool for managing per-worktree PostgreSQL databases directly. Run `db-worktree` with no arguments to see subcommands.

## `env-init` — .env Reinitializer

Reinitializes a `.env` from its `.env.example`, carrying current values forward and interactively reconciling keys that exist in only one file. The example defines the shape (which keys exist and whether each is active or commented out); the old `.env` provides the values. Values transfer into commented-out template keys too (`# KEY=`), which stay commented — and commented values in the old `.env` are still used as a source. Backs up the current `.env` to `<env>.backup.<timestamp>` first. Invoked via `wt env-init` (operates on the current worktree), or standalone: `env-init --env <path> --example <path>`. Run `env-init --help` for usage.

## `env-revert` — .env Backup Restore

Restores a `.env` from one of the `*.backup.*` files `env-init` leaves behind, via an fzf picker (newest first, with a live diff preview) or a direct timestamp. Non-destructive — it backs up the current `.env` before overwriting. Invoked via `wt env-revert [timestamp]`, or standalone: `env-revert --env <path> [timestamp]`. Run `env-revert --help` for usage.

## Library

Shared functions live in `~/dotfiles/lib/postgres.sh`. Scripts source this file; it is not executed directly.

# TypeScript Tooling

`env-init` and `env-revert` are TypeScript run directly by **Bun** (installed via mise) — no build step, no transpile artifacts. The CLI entries are `bin/env-init` and `bin/env-revert`; their pure, I/O-free logic lives in `lib/env-init.ts`, `lib/env-backup.ts`, and `lib/checkbox.ts` (the arrow-key/spacebar multi-select state machine env-init uses for the "differs from template" step) so it can be unit-tested. The raw-terminal TUI in `bin/env-init` falls back to a typed numbered prompt when there's no TTY (piped/headless). These bin scripts are skipped by the pre-commit shellcheck because their shebang is `bun`, not `bash`.

Run the tests:

```bash
bun test            # globs *.test.ts (lib/env-init.test.ts, lib/env-backup.test.ts)
bun test lib/env-backup.test.ts   # a single file
```
