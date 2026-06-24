import { test, expect, describe } from "bun:test";
import {
  parseBackupTimestamp,
  formatBackupTimestamp,
  formatBackupDisplay,
  backupTimestampFromName,
  sortByTimestampDesc,
  relativeAge,
  formatSize,
  diffEnv,
  isNoopDiff,
} from "./env-backup.ts";

describe("parseBackupTimestamp", () => {
  test("parses a valid timestamp to a local Date", () => {
    const d = parseBackupTimestamp("20260620-204916")!;
    expect(d.getFullYear()).toBe(2026);
    expect(d.getMonth()).toBe(5); // June = 5
    expect(d.getDate()).toBe(20);
    expect(d.getHours()).toBe(20);
    expect(d.getMinutes()).toBe(49);
    expect(d.getSeconds()).toBe(16);
  });

  test("parses the optional millisecond field", () => {
    const d = parseBackupTimestamp("20260620-204916123")!;
    expect(d.getSeconds()).toBe(16);
    expect(d.getMilliseconds()).toBe(123);
  });

  test("rejects malformed and impossible timestamps", () => {
    expect(parseBackupTimestamp("2026-06-20")).toBeNull();
    expect(parseBackupTimestamp("20261320-000000")).toBeNull(); // month 13
    expect(parseBackupTimestamp("20260632-000000")).toBeNull(); // day 32
    expect(parseBackupTimestamp("notatimestamp")).toBeNull();
    expect(parseBackupTimestamp("20260620-204916x")).toBeNull();
    expect(parseBackupTimestamp("20260620-20491612")).toBeNull(); // 2-digit ms
  });
});

describe("formatBackupTimestamp / formatBackupDisplay", () => {
  const d = new Date(2026, 5, 20, 21, 8, 54, 123);

  test("format → parse round-trips, including milliseconds", () => {
    const ts = formatBackupTimestamp(d);
    expect(ts).toBe("20260620-210854123");
    expect(parseBackupTimestamp(ts)!.getTime()).toBe(d.getTime());
  });

  test("display is human wall-clock", () => {
    expect(formatBackupDisplay(d)).toBe("2026-06-20 21:08:54");
  });

  test("zero milliseconds still produce a 3-digit field", () => {
    expect(formatBackupTimestamp(new Date(2026, 0, 2, 3, 4, 5, 0))).toBe("20260102-030405000");
  });
});

describe("backupTimestampFromName", () => {
  test("extracts the timestamp for a matching backup name", () => {
    expect(backupTimestampFromName(".env.backup.20260620-204916", ".env")).toBe("20260620-204916");
  });

  test("returns null for non-backups and mismatched bases", () => {
    expect(backupTimestampFromName(".env", ".env")).toBeNull();
    expect(backupTimestampFromName(".env.example", ".env")).toBeNull();
    expect(backupTimestampFromName(".env.backup.garbage", ".env")).toBeNull();
    expect(backupTimestampFromName(".env.local.backup.20260620-204916", ".env")).toBeNull();
  });
});

describe("sortByTimestampDesc", () => {
  test("orders newest first", () => {
    const sorted = sortByTimestampDesc([
      { timestamp: "20260101-000000" },
      { timestamp: "20260620-205000" },
      { timestamp: "20260620-204916" },
    ]);
    expect(sorted.map((b) => b.timestamp)).toEqual([
      "20260620-205000",
      "20260620-204916",
      "20260101-000000",
    ]);
  });

  test("does not mutate the input", () => {
    const input = [{ timestamp: "a" }, { timestamp: "b" }];
    sortByTimestampDesc(input);
    expect(input.map((x) => x.timestamp)).toEqual(["a", "b"]);
  });
});

describe("relativeAge", () => {
  const base = new Date(2026, 5, 20, 12, 0, 0);
  const ago = (s: number) => relativeAge(new Date(base.getTime() - s * 1000), base);

  test("buckets seconds → weeks", () => {
    expect(ago(5)).toBe("just now");
    expect(ago(60)).toBe("1 minute ago");
    expect(ago(600)).toBe("10 minutes ago");
    expect(ago(3600)).toBe("1 hour ago");
    expect(ago(7200)).toBe("2 hours ago");
    expect(ago(86400)).toBe("1 day ago");
    expect(ago(259200)).toBe("3 days ago");
    expect(ago(1209600)).toBe("2 weeks ago");
  });

  test("future timestamps (clock skew) read as 'just now'", () => {
    expect(relativeAge(new Date(base.getTime() + 5000), base)).toBe("just now");
  });
});

describe("formatSize", () => {
  test("bytes, kilobytes, megabytes", () => {
    expect(formatSize(512)).toBe("512B");
    expect(formatSize(1536)).toBe("1.5K");
    expect(formatSize(2 * 1024 * 1024)).toBe("2.0M");
  });
});

describe("diffEnv", () => {
  const current = "A=1\nB=2\nC=3";
  const backup = "A=1\nB=changed\nD=4"; // C removed on revert, D added, B changed
  const d = diffEnv(current, backup);

  test("added = keys the backup has that current lacks", () => {
    expect(d.added).toEqual([{ key: "D", value: "4" }]);
  });

  test("removed = keys current has that the backup lacks", () => {
    expect(d.removed).toEqual([{ key: "C", value: "3" }]);
  });

  test("changed = differing values, current → backup", () => {
    expect(d.changed).toEqual([{ key: "B", from: "2", to: "changed" }]);
  });

  test("identical files diff to a no-op", () => {
    expect(isNoopDiff(diffEnv("A=1\nB=2", "B=2\nA=1"))).toBe(true);
  });

  test("missing current .env makes every backup key an addition", () => {
    const r = diffEnv("", "A=1\nB=2");
    expect(r.added.map((k) => k.key)).toEqual(["A", "B"]);
    expect(r.removed).toEqual([]);
    expect(r.changed).toEqual([]);
  });
});
