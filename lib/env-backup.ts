// env-backup core — pure, no-I/O logic for listing and reverting to the
// timestamped backups that env-init writes (<basename>.backup.<timestamp>).
//
// As with env-init, file/console access is kept out so this can be unit-tested.
// The interactive shell (fzf picker, file copies) lives in bin/env-revert.

import { parseEnvMap, type KeyValue } from "./env-init.ts";

// The timestamp env-init/env-revert stamp onto backups: YYYYMMDD-HHMMSSmmm.
// Milliseconds keep names unique across rapid successive backups (two writes in
// the same second would otherwise clobber each other). The millisecond field is
// optional so any older seconds-only backups still parse and sort correctly.
const TS_RE = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})(\d{3})?$/;
const pad = (n: number, w = 2) => String(n).padStart(w, "0");

/**
 * Parse a backup timestamp into a local Date, or null if malformed. Rejects
 * impossible dates (e.g. month 13) by checking the constructed Date round-trips.
 */
export function parseBackupTimestamp(ts: string): Date | null {
  const m = ts.match(TS_RE);
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1, 7).map(Number);
  const ms = m[7] ? Number(m[7]) : 0;
  const date = new Date(y, mo - 1, d, h, mi, s, ms);
  if (
    date.getFullYear() !== y ||
    date.getMonth() !== mo - 1 ||
    date.getDate() !== d ||
    date.getHours() !== h ||
    date.getMinutes() !== mi ||
    date.getSeconds() !== s
  ) {
    return null;
  }
  return date;
}

/** Format a Date as a backup timestamp (YYYYMMDD-HHMMSSmmm). */
export function formatBackupTimestamp(date: Date): string {
  return (
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}` +
    pad(date.getMilliseconds(), 3)
  );
}

/** Human-readable wall-clock label for a backup date (YYYY-MM-DD HH:MM:SS). */
export function formatBackupDisplay(date: Date): string {
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    ` ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  );
}

/**
 * If `name` is a backup of the file `envBasename` (e.g. ".env"), return its
 * timestamp; otherwise null. Shape: `<envBasename>.backup.<timestamp>`.
 */
export function backupTimestampFromName(
  name: string,
  envBasename: string,
): string | null {
  const prefix = `${envBasename}.backup.`;
  if (!name.startsWith(prefix)) return null;
  const ts = name.slice(prefix.length);
  return parseBackupTimestamp(ts) ? ts : null;
}

export interface Backup {
  timestamp: string;
  date: Date;
}

/** Sort backups newest-first by timestamp (lexical order == chronological). */
export function sortByTimestampDesc<T extends { timestamp: string }>(items: T[]): T[] {
  return items.slice().sort((a, b) => (a.timestamp < b.timestamp ? 1 : a.timestamp > b.timestamp ? -1 : 0));
}

/** Human-friendly "2 hours ago" style age. `now` is injected for testability. */
export function relativeAge(then: Date, now: Date): string {
  let secs = Math.floor((now.getTime() - then.getTime()) / 1000);
  if (secs < 0) secs = 0;
  const unit = (n: number, name: string) => `${n} ${name}${n === 1 ? "" : "s"} ago`;
  if (secs < 60) return "just now";
  if (secs < 3600) return unit(Math.floor(secs / 60), "minute");
  if (secs < 86400) return unit(Math.floor(secs / 3600), "hour");
  if (secs < 604800) return unit(Math.floor(secs / 86400), "day");
  return unit(Math.floor(secs / 604800), "week");
}

/** Compact byte-size label: 512B, 1.3K, 2.0M. */
export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}K`;
  return `${(bytes / 1024 / 1024).toFixed(1)}M`;
}

export interface EnvDiff {
  /** Keys in the backup but not in current — reverting would add these. */
  added: KeyValue[];
  /** Keys in current but not in the backup — reverting would remove these. */
  removed: KeyValue[];
  /** Keys in both whose value differs — reverting changes current → backup. */
  changed: { key: string; from: string; to: string }[];
}

/**
 * Diff describing what reverting the current .env to `backupText` would do.
 * Buckets are sorted by key for stable output. `current` may be empty (no .env).
 */
export function diffEnv(currentText: string, backupText: string): EnvDiff {
  const cur = parseEnvMap(currentText);
  const bak = parseEnvMap(backupText);
  const byKey = (a: { key: string }, b: { key: string }) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

  const added: KeyValue[] = [];
  const changed: EnvDiff["changed"] = [];
  for (const [key, value] of bak) {
    if (!cur.has(key)) added.push({ key, value });
    else if (cur.get(key) !== value) changed.push({ key, from: cur.get(key)!, to: value });
  }
  const removed: KeyValue[] = [];
  for (const [key, value] of cur) {
    if (!bak.has(key)) removed.push({ key, value });
  }

  return {
    added: added.sort(byKey),
    removed: removed.sort(byKey),
    changed: changed.sort(byKey),
  };
}

/** True when reverting to this backup would change nothing. */
export function isNoopDiff(d: EnvDiff): boolean {
  return d.added.length === 0 && d.removed.length === 0 && d.changed.length === 0;
}
