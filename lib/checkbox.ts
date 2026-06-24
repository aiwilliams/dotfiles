// checkbox — pure state machine for an arrow-key + spacebar multi-select list.
//
// All terminal I/O (raw mode, redraw) lives in the caller; this module is just
// the model: decode a keypress, reduce it into new state, and render the list to
// plain lines. Keeping it I/O-free makes the navigation logic unit-testable.

export type CheckboxKey =
  | "up"
  | "down"
  | "toggle"
  | "all"
  | "none"
  | "invert"
  | "submit"
  | "cancel"
  | "abort"
  | "noop";

export interface CheckboxState {
  /** Index of the highlighted row. */
  cursor: number;
  /** Per-row checked flag (parallel to the item list). */
  checked: boolean[];
}

export function initCheckboxState(count: number, initial?: boolean[]): CheckboxState {
  return {
    cursor: 0,
    checked: Array.from({ length: count }, (_, i) => initial?.[i] ?? false),
  };
}

/**
 * Map a raw stdin chunk to a logical key. Handles arrow keys (both normal and
 * application-cursor escape sequences), vim h/j/k/l-style nav, space, enter,
 * Esc, and Ctrl-C. Anything unrecognized is "noop".
 */
export function decodeKey(seq: string): CheckboxKey {
  switch (seq) {
    case "\x03": return "abort"; // Ctrl-C
    case "\x1b[A":
    case "\x1bOA":
    case "k": return "up";
    case "\x1b[B":
    case "\x1bOB":
    case "j": return "down";
    case "\r":
    case "\n": return "submit";
    case " ": return "toggle";
    case "a": return "all";
    case "n": return "none";
    case "i": return "invert";
    case "\x1b": // bare Esc
    case "q": return "cancel";
    default: return "noop";
  }
}

/**
 * Split a raw stdin chunk into individual key tokens. A terminal usually sends
 * one keystroke per chunk, but fast key-repeat (or piped input) can batch
 * several together — including multi-byte escape sequences for arrows. Peels
 * off CSI/SS3 sequences (ESC [ X / ESC O X) whole; every other byte is its own
 * token.
 */
export function splitKeys(seq: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  while (i < seq.length) {
    if (seq[i] === "\x1b" && (seq[i + 1] === "[" || seq[i + 1] === "O") && i + 2 < seq.length) {
      tokens.push(seq.slice(i, i + 3));
      i += 3;
    } else {
      tokens.push(seq[i]);
      i += 1;
    }
  }
  return tokens;
}

/** Apply a key to the state, returning new state (or the same ref on a no-op). */
export function reduceCheckbox(state: CheckboxState, key: CheckboxKey): CheckboxState {
  const n = state.checked.length;
  if (n === 0) return state;
  switch (key) {
    case "up":
      return { ...state, cursor: (state.cursor - 1 + n) % n };
    case "down":
      return { ...state, cursor: (state.cursor + 1) % n };
    case "toggle": {
      const checked = state.checked.slice();
      checked[state.cursor] = !checked[state.cursor];
      return { ...state, checked };
    }
    case "all":
      return { ...state, checked: state.checked.map(() => true) };
    case "none":
      return { ...state, checked: state.checked.map(() => false) };
    case "invert":
      return { ...state, checked: state.checked.map((c) => !c) };
    default:
      return state;
  }
}

export interface CheckboxItem {
  label: string;
  hint?: string;
}

/**
 * Render the list as plain lines (no ANSI), aligned. The caller decorates the
 * cursor row. Pointer marks the cursor; [x]/[ ] marks checked state.
 */
export function renderCheckbox(items: CheckboxItem[], state: CheckboxState): string[] {
  const labelW = items.reduce((w, it) => Math.max(w, it.label.length), 0);
  return items.map((it, i) => {
    const pointer = i === state.cursor ? "❯" : " "; // ❯
    const box = state.checked[i] ? "[x]" : "[ ]";
    const hint = it.hint ? `  ${it.hint}` : "";
    return `${pointer} ${box} ${it.label.padEnd(labelW)}${hint}`;
  });
}

/**
 * Hard-wrap text into chunks of at most `width` characters (breaking anywhere,
 * since env values are often unbroken strings like URLs or tokens). An empty
 * string yields a single empty line; width <= 0 returns the text unwrapped.
 */
export function wrapHard(text: string, width: number): string[] {
  if (width <= 0) return [text];
  if (text.length === 0) return [""];
  const out: string[] = [];
  for (let i = 0; i < text.length; i += width) out.push(text.slice(i, i + width));
  return out;
}

/** Indices currently checked, ascending — the selection. */
export function selectedIndices(state: CheckboxState): number[] {
  const out: number[] = [];
  state.checked.forEach((c, i) => {
    if (c) out.push(i);
  });
  return out;
}
