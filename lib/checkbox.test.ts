import { test, expect, describe } from "bun:test";
import {
  initCheckboxState,
  decodeKey,
  splitKeys,
  reduceCheckbox,
  renderCheckbox,
  selectedIndices,
  wrapHard,
  type CheckboxState,
} from "./checkbox.ts";

describe("initCheckboxState", () => {
  test("starts at cursor 0, all unchecked by default", () => {
    expect(initCheckboxState(3)).toEqual({ cursor: 0, checked: [false, false, false] });
  });

  test("honors an initial checked mask", () => {
    expect(initCheckboxState(3, [true, false, true]).checked).toEqual([true, false, true]);
  });
});

describe("decodeKey", () => {
  test("arrow keys (normal and application-cursor)", () => {
    expect(decodeKey("\x1b[A")).toBe("up");
    expect(decodeKey("\x1bOA")).toBe("up");
    expect(decodeKey("\x1b[B")).toBe("down");
    expect(decodeKey("\x1bOB")).toBe("down");
  });

  test("vim nav, space, enter", () => {
    expect(decodeKey("k")).toBe("up");
    expect(decodeKey("j")).toBe("down");
    expect(decodeKey(" ")).toBe("toggle");
    expect(decodeKey("\r")).toBe("submit");
    expect(decodeKey("\n")).toBe("submit");
  });

  test("bulk ops, cancel, abort, and noop", () => {
    expect(decodeKey("a")).toBe("all");
    expect(decodeKey("n")).toBe("none");
    expect(decodeKey("i")).toBe("invert");
    expect(decodeKey("\x1b")).toBe("cancel");
    expect(decodeKey("q")).toBe("cancel");
    expect(decodeKey("\x03")).toBe("abort");
    expect(decodeKey("z")).toBe("noop");
  });
});

describe("splitKeys", () => {
  test("single keystroke passes through", () => {
    expect(splitKeys(" ")).toEqual([" "]);
    expect(splitKeys("\x1b[A")).toEqual(["\x1b[A"]);
  });

  test("a batched chunk splits into individual keys", () => {
    // down, space, down, down, space, enter
    expect(splitKeys("\x1b[B \x1b[B\x1b[B \r")).toEqual(["\x1b[B", " ", "\x1b[B", "\x1b[B", " ", "\r"]);
  });

  test("decoding each token recovers the intended keys", () => {
    expect(splitKeys("\x1b[B \r").map(decodeKey)).toEqual(["down", "toggle", "submit"]);
  });

  test("a trailing bare ESC stays its own token", () => {
    expect(splitKeys("j\x1b")).toEqual(["j", "\x1b"]);
  });
});

describe("reduceCheckbox", () => {
  const base: CheckboxState = { cursor: 0, checked: [false, false, false] };

  test("down/up move the cursor and wrap around", () => {
    expect(reduceCheckbox(base, "down").cursor).toBe(1);
    expect(reduceCheckbox({ ...base, cursor: 2 }, "down").cursor).toBe(0); // wrap end→start
    expect(reduceCheckbox(base, "up").cursor).toBe(2); // wrap start→end
  });

  test("toggle flips only the cursor row", () => {
    const s = reduceCheckbox({ ...base, cursor: 1 }, "toggle");
    expect(s.checked).toEqual([false, true, false]);
    expect(reduceCheckbox(s, "toggle").checked).toEqual([false, false, false]);
  });

  test("all / none / invert", () => {
    expect(reduceCheckbox(base, "all").checked).toEqual([true, true, true]);
    const mixed = { cursor: 0, checked: [true, false, true] };
    expect(reduceCheckbox(mixed, "none").checked).toEqual([false, false, false]);
    expect(reduceCheckbox(mixed, "invert").checked).toEqual([false, true, false]);
  });

  test("noop and empty list return the same reference", () => {
    expect(reduceCheckbox(base, "noop")).toBe(base);
    const empty = { cursor: 0, checked: [] as boolean[] };
    expect(reduceCheckbox(empty, "down")).toBe(empty);
  });
});

describe("renderCheckbox", () => {
  const items = [
    { label: "LOG_LEVEL", hint: "debug → info" },
    { label: "DB", hint: "a → b" },
  ];

  test("marks the cursor row and checked boxes, aligned by label", () => {
    const state = { cursor: 0, checked: [true, false] };
    expect(renderCheckbox(items, state)).toEqual([
      "❯ [x] LOG_LEVEL  debug → info",
      "  [ ] DB         a → b",
    ]);
  });

  test("renders without hints", () => {
    expect(renderCheckbox([{ label: "X" }], { cursor: 0, checked: [false] })).toEqual(["❯ [ ] X"]);
  });
});

describe("selectedIndices", () => {
  test("returns ascending indices of checked rows", () => {
    expect(selectedIndices({ cursor: 0, checked: [false, true, true, false] })).toEqual([1, 2]);
    expect(selectedIndices({ cursor: 0, checked: [false, false] })).toEqual([]);
  });
});

describe("wrapHard", () => {
  test("breaks into fixed-width chunks", () => {
    expect(wrapHard("abcdefg", 3)).toEqual(["abc", "def", "g"]);
  });

  test("short text and empty string", () => {
    expect(wrapHard("ab", 5)).toEqual(["ab"]);
    expect(wrapHard("", 5)).toEqual([""]);
  });

  test("non-positive width returns text unwrapped", () => {
    expect(wrapHard("abc", 0)).toEqual(["abc"]);
  });
});

describe("integration: a key sequence drives a selection", () => {
  test("down, space, down, down, space, enter → rows 1 and 3", () => {
    let s = initCheckboxState(4);
    for (const seq of ["\x1b[B", " ", "\x1b[B", "\x1b[B", " "]) {
      s = reduceCheckbox(s, decodeKey(seq));
    }
    // submit is terminal; selection is read from state.
    expect(decodeKey("\r")).toBe("submit");
    expect(selectedIndices(s)).toEqual([1, 3]);
  });
});
