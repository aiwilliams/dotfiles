import { test, expect, describe } from "bun:test";
import {
  parseEnvLines,
  envMap,
  parseEnvMap,
  collectValues,
  serialize,
  pairLine,
  commentPairLine,
  reconcile,
  appendCarried,
  applyValues,
  parseSelection,
} from "./env-init.ts";

describe("parseEnvLines", () => {
  test("classifies pairs, prose comments, commented assignments, and blanks", () => {
    const lines = parseEnvLines("# comment\n\nFOO=bar\nNOPE\n# BAR=baz\n#BAZ=1");
    expect(lines.map((l) => l.kind)).toEqual([
      "raw", // prose comment
      "raw", // blank
      "pair", // FOO=bar
      "raw", // NOPE (no '=')
      "comment-pair", // # BAR=baz
      "comment-pair", // #BAZ=1 (no space)
    ]);
  });

  test("commented assignment captures key and value; prose stays raw", () => {
    const [cp] = parseEnvLines("#  PROXY_DOMAIN=opine.localhost");
    expect(cp).toEqual({ kind: "comment-pair", key: "PROXY_DOMAIN", value: "opine.localhost", raw: "#  PROXY_DOMAIN=opine.localhost" });
    // Prose that merely mentions an assignment is not a comment-pair.
    expect(parseEnvLines("# set FOO=bar to enable")[0].kind).toBe("raw");
  });

  test("value is everything after the first '=' verbatim", () => {
    const [line] = parseEnvLines("URL=postgres://u:p@h/db?x=1#frag");
    expect(line).toEqual({
      kind: "pair",
      key: "URL",
      value: "postgres://u:p@h/db?x=1#frag",
      raw: "URL=postgres://u:p@h/db?x=1#frag",
    });
  });

  test("empty value is a valid pair", () => {
    const [line] = parseEnvLines("EMPTY=");
    expect(line).toEqual({ kind: "pair", key: "EMPTY", value: "", raw: "EMPTY=" });
  });

  test("keeps quotes and surrounding whitespace in the value", () => {
    const map = parseEnvMap('Q="hello world"  ');
    expect(map.get("Q")).toBe('"hello world"  ');
  });

  test("lines starting with a digit or space are not pairs", () => {
    const lines = parseEnvLines("1FOO=bar\n LEADING=space");
    expect(lines.every((l) => l.kind === "raw")).toBe(true);
  });

  test("empty text yields no lines; trailing newline adds no blank", () => {
    expect(parseEnvLines("")).toEqual([]);
    expect(parseEnvLines("A=1\n").length).toBe(1);
  });

  test("strips CR from CRLF line endings", () => {
    const [line] = parseEnvLines("A=1\r\nB=2\r\n");
    expect(line.raw).toBe("A=1");
    expect((line as { value: string }).value).toBe("1");
  });
});

describe("envMap", () => {
  test("last occurrence wins; commented lines are not active values", () => {
    expect(parseEnvMap("A=1\nA=2\nB=3").get("A")).toBe("2");
    expect(parseEnvMap("# A=commented\nB=2").has("A")).toBe(false);
  });
});

describe("collectValues", () => {
  test("includes commented values but lets an active value win", () => {
    const m = collectValues(parseEnvLines("# A=fromcomment\nB=2\nA=active"));
    expect(m.get("A")).toEqual({ value: "active", commented: false });
    expect(m.get("B")).toEqual({ value: "2", commented: false });
  });

  test("a commented-only key is collected as commented", () => {
    const m = collectValues(parseEnvLines("# OPT=on"));
    expect(m.get("OPT")).toEqual({ value: "on", commented: true });
  });

  test("keys keep first-seen file order (commented and active interleaved)", () => {
    const m = collectValues(parseEnvLines("ACTIVE=1\n# COMMENTED=2\nLAST=3"));
    expect([...m.keys()]).toEqual(["ACTIVE", "COMMENTED", "LAST"]);
  });
});

describe("serialize", () => {
  test("round-trips through parse and ends with a single newline", () => {
    const text = "# top\nA=1\n\nB=two\n";
    expect(serialize(parseEnvLines(text))).toBe(text);
  });

  test("empty line list serializes to empty string", () => {
    expect(serialize([])).toBe("");
  });
});

describe("reconcile", () => {
  const example = parseEnvLines(
    [
      "# Database",
      "DB_URL=postgres://localhost/example",
      "PORT=3000",
      "",
      "# New feature flag",
      "FEATURE_X=false",
    ].join("\n"),
  );
  const backup = parseEnvLines(
    ["DB_URL=postgres://localhost/real", "PORT=3007", "OLD_TOKEN=secret123"].join("\n"),
  );
  const result = reconcile(example, backup);

  test("shared keys take the backup value but keep example position/comments", () => {
    expect(serialize(result.merged)).toBe(
      [
        "# Database",
        "DB_URL=postgres://localhost/real",
        "PORT=3007",
        "",
        "# New feature flag",
        "FEATURE_X=false",
        "",
      ].join("\n"),
    );
    expect(result.carriedOver.sort()).toEqual(["DB_URL", "PORT"]);
  });

  test("backupOnly = keys in backup but not example, with comment state", () => {
    expect(result.backupOnly).toEqual([{ key: "OLD_TOKEN", value: "secret123", commented: false }]);
  });

  test("exampleOnly = active example keys not in backup, with example default", () => {
    expect(result.exampleOnly).toEqual([{ key: "FEATURE_X", value: "false" }]);
  });

  test("empty backup carries nothing; every active example key is exampleOnly", () => {
    const r = reconcile(example, []);
    expect(r.carriedOver).toEqual([]);
    expect(r.backupOnly).toEqual([]);
    expect(r.changed).toEqual([]);
    expect(r.exampleOnly.map((k) => k.key)).toEqual(["DB_URL", "PORT", "FEATURE_X"]);
  });

  describe("comment state follows YOUR .env (refresh without losing settings)", () => {
    test("commented example key + active backup value → stays ACTIVE (your state wins)", () => {
      const r = reconcile(parseEnvLines("# PROXY_DOMAIN=\nDB=x"), parseEnvLines("PROXY_DOMAIN=opine.localhost\nDB=real"));
      expect(serialize(r.merged)).toBe("PROXY_DOMAIN=opine.localhost\nDB=real\n");
      expect(r.carriedOver.sort()).toEqual(["DB", "PROXY_DOMAIN"]);
      expect(r.backupOnly).toEqual([]); // known to the example, just commented there
    });

    test("active example key + commented backup value → stays COMMENTED (your state wins)", () => {
      const r = reconcile(parseEnvLines("FLAG=default"), parseEnvLines("# FLAG=on"));
      expect(serialize(r.merged)).toBe("# FLAG=on\n");
      expect(r.carriedOver).toEqual(["FLAG"]);
    });

    test("commented example key with no backup value is left untouched and not nagged", () => {
      const r = reconcile(parseEnvLines("# OPTIONAL=somedefault\nA=1"), parseEnvLines("A=1"));
      expect(serialize(r.merged)).toBe("# OPTIONAL=somedefault\nA=1\n");
      expect(r.exampleOnly).toEqual([]);
      expect(r.backupOnly).toEqual([]);
    });

    test("commented backup-only key keeps its commented state in backupOnly", () => {
      const r = reconcile(parseEnvLines("A=1"), parseEnvLines("A=1\n# CUSTOM=local"));
      expect(r.backupOnly).toEqual([{ key: "CUSTOM", value: "local", commented: true }]);
    });

    test("a key duplicated in the example lands once, at its first position", () => {
      const r = reconcile(parseEnvLines("# KEY=\nOTHER=1\nKEY=def"), parseEnvLines("KEY=mine"));
      expect(serialize(r.merged)).toBe("KEY=mine\nOTHER=1\n");
    });
  });

  describe("changed (template's active default differs from yours)", () => {
    test("reports mine vs theirs; merged keeps your value by default", () => {
      const r = reconcile(parseEnvLines("LOG=info\nDB=x"), parseEnvLines("LOG=debug\nDB=x"));
      expect(r.changed).toEqual([{ key: "LOG", mine: "debug", theirs: "info" }]);
      expect(serialize(r.merged)).toBe("LOG=debug\nDB=x\n"); // kept yours
    });

    test("empty template default is not a 'change' (it's just a placeholder)", () => {
      const r = reconcile(parseEnvLines("API_KEY="), parseEnvLines("API_KEY=secret"));
      expect(r.changed).toEqual([]);
    });

    test("a commented template default does not count as the team's default", () => {
      const r = reconcile(parseEnvLines("# LOG=info"), parseEnvLines("LOG=debug"));
      expect(r.changed).toEqual([]);
    });

    test("adopting theirs via applyValues keeps your comment state", () => {
      // You have LOG commented; you opt into the team's value.
      const r = reconcile(parseEnvLines("LOG=info"), parseEnvLines("# LOG=debug"));
      const adopted = applyValues(r.merged, new Map([["LOG", "info"]]));
      expect(serialize(adopted)).toBe("# LOG=info\n"); // value adopted, still commented
    });
  });
});

describe("appendCarried", () => {
  test("appends selected keys under a header, separated by a blank line", () => {
    const merged = [pairLine("A", "1")];
    const out = appendCarried(merged, [{ key: "OLD", value: "x", commented: false }]);
    expect(serialize(out)).toBe("A=1\n\n# Carried over from previous .env\nOLD=x\n");
  });

  test("a commented backup-only key is re-added commented", () => {
    const out = appendCarried([pairLine("A", "1")], [{ key: "OLD", value: "x", commented: true }]);
    expect(serialize(out)).toBe("A=1\n\n# Carried over from previous .env\n# OLD=x\n");
  });

  test("no additions is a no-op (fresh copy)", () => {
    const merged = [pairLine("A", "1")];
    expect(serialize(appendCarried(merged, []))).toBe("A=1\n");
  });
});

describe("applyValues", () => {
  test("replaces the value for matching keys only", () => {
    const lines = parseEnvLines("A=1\nB=2\n# c\nC=3");
    const out = applyValues(lines, new Map([["B", "changed"]]));
    expect(serialize(out)).toBe("A=1\nB=changed\n# c\nC=3\n");
  });

  test("updates a commented assignment in place, keeping it commented", () => {
    const lines = parseEnvLines("# OPT=old\nA=1");
    const out = applyValues(lines, new Map([["OPT", "new"]]));
    expect(serialize(out)).toBe("# OPT=new\nA=1\n");
  });
});

describe("parseSelection", () => {
  test("empty and 'none' select nothing", () => {
    expect(parseSelection("", 5)).toEqual([]);
    expect(parseSelection("  none ", 5)).toEqual([]);
  });

  test("'all' selects every 0-based index", () => {
    expect(parseSelection("all", 3)).toEqual([0, 1, 2]);
  });

  test("space- and comma-separated indices, deduped and sorted", () => {
    expect(parseSelection("3 1, 1  2", 5)).toEqual([0, 1, 2]);
  });

  test("ranges expand inclusively", () => {
    expect(parseSelection("2-4", 5)).toEqual([1, 2, 3]);
    expect(parseSelection("1,3-5", 5)).toEqual([0, 2, 3, 4]);
  });

  test("throws on out-of-range, non-numeric, and reversed ranges", () => {
    expect(() => parseSelection("6", 5)).toThrow();
    expect(() => parseSelection("0", 5)).toThrow();
    expect(() => parseSelection("x", 5)).toThrow();
    expect(() => parseSelection("4-2", 5)).toThrow();
  });
});
