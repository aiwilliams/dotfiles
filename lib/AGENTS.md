# Worktree & Database Management

Local development uses native PostgreSQL 18 with pgvector (not Docker). Two CLI tools in `~/dotfiles/bin/` manage worktrees and databases. Run each command with `--help` or no arguments to see available subcommands and usage.

## `wt` — Git Worktree Manager

Creates worktrees as sibling directories with auto-numbered IDs. Automatically clones databases, wires `.env`, and runs project setup. Run `wt help` for full documentation.

## `pg` — PostgreSQL Query Runner

Execute SQL against project databases using connection info from `.env` files. Auto-discovers `.env` in the current directory or `apps/platform/.env` from the git root. Use `-d vector` for the vector database. Run `pg -h` for full usage.

## `db-worktree` — Database Manager

Lower-level tool for managing per-worktree PostgreSQL databases directly. Run `db-worktree` with no arguments to see subcommands.

## Library

Shared functions live in `~/dotfiles/lib/postgres.sh`. Scripts source this file; it is not executed directly.
