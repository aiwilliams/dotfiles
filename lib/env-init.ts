// env-init core — pure, no-I/O logic for reinitializing a .env from a fresh
// .env.example while carrying forward values from the previous .env.
//
// Kept free of file/console/prompt access so it can be unit-tested with bun
// test. The interactive shell lives in bin/env-init.
//
// Key/value parsing intentionally mirrors wt's parse_env_kv: a line is a pair
// only if it matches /^[A-Za-z_][A-Za-z0-9_]*=/; everything after the first '='
// is the value, verbatim (quotes, spaces, and inline comments included). All
// other lines (comments, blanks, anything else) are preserved as raw text so
// the example's structure and grouping survive a reinit.

export type Line =
  | { kind: "pair"; key: string; value: string; raw: string }
  // A commented-out assignment, e.g. `# PROXY_DOMAIN=`. The .env.example
  // convention for documenting an optional setting and where it belongs. It is
  // not an active value, but it IS a key the template knows about.
  | { kind: "comment-pair"; key: string; value: string; raw: string }
  | { kind: "raw"; raw: string };

const PAIR_RE = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
// A comment whose body is exactly an assignment: optional indent, `#`, optional
// space, then KEY=… with nothing between the key and `=`. Prose like
// "# set FOO=bar to enable" does not match (FOO isn't immediately after `#`).
const COMMENT_PAIR_RE = /^\s*#\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;

/** Build an active pair line, keeping raw in sync with key/value. */
export function pairLine(key: string, value: string): Line {
  return { kind: "pair", key, value, raw: `${key}=${value}` };
}

/** Build a commented-out pair line (`# KEY=value`). */
export function commentPairLine(key: string, value: string): Line {
  return { kind: "comment-pair", key, value, raw: `# ${key}=${value}` };
}

/** Parse .env text into ordered lines, preserving comments and blanks. */
export function parseEnvLines(text: string): Line[] {
  if (text === "") return [];
  // Drop a single trailing newline so we don't manufacture a blank line.
  const body = text.endsWith("\n") ? text.slice(0, -1) : text;
  return body.split("\n").map((rawWithCr) => {
    const raw = rawWithCr.endsWith("\r") ? rawWithCr.slice(0, -1) : rawWithCr;
    const pair = raw.match(PAIR_RE);
    if (pair) return { kind: "pair", key: pair[1], value: pair[2], raw } as Line;
    const commented = raw.match(COMMENT_PAIR_RE);
    if (commented) {
      return { kind: "comment-pair", key: commented[1], value: commented[2], raw } as Line;
    }
    return { kind: "raw", raw } as Line;
  });
}

/** Last-occurrence-wins map of key → value, matching shell env semantics. */
export function envMap(lines: Line[]): Map<string, string> {
  const map = new Map<string, string>();
  for (const line of lines) {
    if (line.kind === "pair") map.set(line.key, line.value);
  }
  return map;
}

/** Convenience: parse text straight to a key → value map. */
export function parseEnvMap(text: string): Map<string, string> {
  return envMap(parseEnvLines(text));
}

export interface EnvValue {
  value: string;
  /** True if the value came from a commented-out line (`# KEY=value`). */
  commented: boolean;
}

/**
 * Collect every key's value, from both active and commented-out assignments —
 * we don't ignore commented vars when sourcing values. Keys keep their first-
 * seen order. An active value always wins over a commented one for the same key
 * (and marks it not-commented); within each kind, last wins.
 */
export function collectValues(lines: Line[]): Map<string, EnvValue> {
  const out = new Map<string, EnvValue>();
  const hasActive = new Set<string>();
  for (const line of lines) {
    if (line.kind === "pair") {
      // Active wins value and comment state; Map.set keeps first-seen position.
      out.set(line.key, { value: line.value, commented: false });
      hasActive.add(line.key);
    } else if (line.kind === "comment-pair" && !hasActive.has(line.key)) {
      out.set(line.key, { value: line.value, commented: true });
    }
  }
  return out;
}

/** Serialize lines back to .env text, always ending with a trailing newline. */
export function serialize(lines: Line[]): string {
  if (lines.length === 0) return "";
  return lines.map((l) => l.raw).join("\n") + "\n";
}

export interface KeyValue {
  key: string;
  value: string;
}

export interface BackupEntry extends KeyValue {
  /** Whether this key was commented out in the backup .env. */
  commented: boolean;
}

export interface ChangedEntry {
  key: string;
  /** Your current value (the default — kept unless you opt into theirs). */
  mine: string;
  /** The template's active default value, which differs from yours. */
  theirs: string;
}

export interface ReconcileResult {
  /**
   * The example's lines, but for every key you already have, your value AND
   * your comment state (active vs commented) win — the goal is to refresh your
   * .env to the template's shape without losing or silently disabling settings.
   */
  merged: Line[];
  /** Keys the backup and example share (your value kept in merged). */
  carriedOver: string[];
  /** Keys where the template's active default differs from your value. */
  changed: ChangedEntry[];
  /** Keys in the backup the example doesn't mention (candidates to add). */
  backupOnly: BackupEntry[];
  /** Active example keys the backup has no value for (candidates to fill in). */
  exampleOnly: KeyValue[];
}

/**
 * Reconcile a fresh example against the previous .env.
 *
 * The example defines the *shape* (which keys exist and their order/comments);
 * your previous .env provides the *values* and, for keys you already have, the
 * *active-vs-commented state*. So refreshing never loses a value or silently
 * flips a setting you'd enabled or disabled. Commented vars are not ignored: a
 * commented value in the backup is still used as a source.
 *
 *   example `KEY=`      + backup `KEY=v`   → `KEY=v`     (yours; active)
 *   example `# KEY=`    + backup `KEY=v`   → `KEY=v`     (yours; YOUR active state wins)
 *   example `KEY=`      + backup `# KEY=v` → `# KEY=v`   (yours; YOUR commented state wins)
 *
 * - changed: keys whose template *active* default (non-empty) differs from your
 *   value — surfaced so you can optionally adopt the team's value.
 * - backupOnly: keys the example doesn't mention at all (active or commented),
 *   carrying their backup comment state so they can be re-added in kind.
 * - exampleOnly: active example keys the backup has no value for.
 *
 * Order is deterministic: backupOnly follows the backup's first-seen order,
 * changed/exampleOnly follow the example's order.
 */
export function reconcile(
  exampleLines: Line[],
  backupLines: Line[],
): ReconcileResult {
  const backup = collectValues(backupLines);
  const exampleKeys = new Set<string>();
  const carriedOver: string[] = [];
  const emitted = new Set<string>();

  const merged: Line[] = [];
  for (const line of exampleLines) {
    if (line.kind === "pair" || line.kind === "comment-pair") {
      exampleKeys.add(line.key);
      if (backup.has(line.key)) {
        // Your value and your comment state win. Drop duplicate occurrences of
        // the same key so it lands exactly once, at its first template position.
        if (emitted.has(line.key)) continue;
        emitted.add(line.key);
        carriedOver.push(line.key);
        const { value, commented } = backup.get(line.key)!;
        merged.push(commented ? commentPairLine(line.key, value) : pairLine(line.key, value));
      } else {
        merged.push(line);
      }
    } else {
      merged.push(line);
    }
  }

  // changed: the template's *active* default differs from your value. Commented
  // template lines are placeholders/examples, not the team's chosen default, so
  // they don't count here.
  const changed: ChangedEntry[] = [];
  const seenChanged = new Set<string>();
  for (const line of exampleLines) {
    if (line.kind !== "pair" || seenChanged.has(line.key)) continue;
    if (!backup.has(line.key)) continue;
    const mine = backup.get(line.key)!.value;
    if (line.value !== "" && line.value !== mine) {
      seenChanged.add(line.key);
      changed.push({ key: line.key, mine, theirs: line.value });
    }
  }

  const backupOnly: BackupEntry[] = [];
  for (const [key, { value, commented }] of backup) {
    if (!exampleKeys.has(key)) backupOnly.push({ key, value, commented });
  }

  const exampleOnly: KeyValue[] = [];
  const seenExampleOnly = new Set<string>();
  for (const line of exampleLines) {
    if (line.kind !== "pair") continue; // commented example keys stay off; not nagged
    if (backup.has(line.key) || seenExampleOnly.has(line.key)) continue;
    seenExampleOnly.add(line.key);
    exampleOnly.push({ key: line.key, value: line.value });
  }

  return { merged, carriedOver, changed, backupOnly, exampleOnly };
}

/**
 * Append selected backup-only keys to the merged lines, under a header comment
 * so it's obvious where they came from. Each entry keeps its backup comment
 * state (a commented backup var is re-added commented). Returns a new array.
 */
export function appendCarried(merged: Line[], additions: BackupEntry[]): Line[] {
  if (additions.length === 0) return merged.slice();
  const out = merged.slice();
  // Separate the carried block with a blank line unless the file is empty.
  if (out.length > 0 && out[out.length - 1].raw !== "") {
    out.push({ kind: "raw", raw: "" });
  }
  out.push({ kind: "raw", raw: "# Carried over from previous .env" });
  for (const { key, value, commented } of additions) {
    out.push(commented ? commentPairLine(key, value) : pairLine(key, value));
  }
  return out;
}

/**
 * Replace the value of each given key in-place (every occurrence), preserving
 * the line's comment state. Used to fill in example-only keys and to adopt the
 * template's value for changed keys. Returns a new array.
 */
export function applyValues(lines: Line[], values: Map<string, string>): Line[] {
  return lines.map((line) => {
    if ((line.kind === "pair" || line.kind === "comment-pair") && values.has(line.key)) {
      const value = values.get(line.key)!;
      return line.kind === "pair" ? pairLine(line.key, value) : commentPairLine(line.key, value);
    }
    return line;
  });
}

/**
 * Parse a row-selection string against a 1-based list of `count` rows.
 *
 * Accepts space- and/or comma-separated indices and ranges, e.g.
 *   "1 3 5", "1,3,5", "2-4", "1, 3-5 7", "all", "none", "".
 * Empty input and "none" select nothing; "all" selects everything.
 *
 * Returns sorted, de-duplicated 0-based indices. Throws on non-numeric tokens,
 * malformed ranges, or out-of-range values so the caller can re-prompt.
 */
export function parseSelection(input: string, count: number): number[] {
  const trimmed = input.trim().toLowerCase();
  if (trimmed === "" || trimmed === "none") return [];
  if (trimmed === "all") return Array.from({ length: count }, (_, i) => i);

  const picked = new Set<number>();
  const add = (oneBased: number) => {
    if (!Number.isInteger(oneBased) || oneBased < 1 || oneBased > count) {
      throw new Error(`'${oneBased}' is out of range (1-${count})`);
    }
    picked.add(oneBased - 1);
  };

  for (const token of trimmed.split(/[\s,]+/).filter(Boolean)) {
    const range = token.match(/^(\d+)-(\d+)$/);
    if (range) {
      const start = Number(range[1]);
      const end = Number(range[2]);
      if (start > end) throw new Error(`invalid range '${token}'`);
      for (let n = start; n <= end; n++) add(n);
      continue;
    }
    if (!/^\d+$/.test(token)) throw new Error(`invalid selection '${token}'`);
    add(Number(token));
  }

  return Array.from(picked).sort((a, b) => a - b);
}
