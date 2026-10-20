// Alias black-box contract tests for the `thru` CLI.
// Spec: docs/specs/aliases-spec.md. Drives the compiled binary via Bun.spawn only.
// Every test runs against its own temp HOME so the real ~/.config/thru is never touched.
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = process.env.THRU_BIN ?? new URL("../.build/release/thru", import.meta.url).pathname;
const HW = process.env.THRU_HW === "1";
const IN_TEXT = process.env.THRU_IN ?? "quad cortex";
const OUT_TEXT = process.env.THRU_OUT ?? "audiofuse";

const MISSING_IN = "zz-no-such-input-device";
const MISSING_OUT = "zz-no-such-output-device";
const FAKE_DEVICE = "zz-fake-device";
const FAKE_DEVICE_2 = "zz-fake-device-2";

const CONNECTED_RE =
  /^thru: connected (.+?) -> (.+?) map=(\S+) buffer=(\d+) first-audio=(\d+(?:\.\d+)?)ms\r?$/m;
const COMMAND_WORDS = new Set(["alias", "list", "inspect", "map-check", "help"]);

interface Run {
  proc: Bun.Subprocess;
  spawnedAt: number;
  drained: Promise<void>;
  out: () => string;
  err: () => string;
}

// Every child spawned by a test is registered here and killed in afterEach,
// so no process (and therefore no private aggregate) outlives its test.
const live = new Set<Bun.Subprocess>();
const tempDirs: string[] = [];

afterEach(async () => {
  for (const proc of live) {
    try {
      proc.kill("SIGKILL");
    } catch {
      // already exited
    }
    try {
      await proc.exited;
    } catch {
      // ignore
    }
  }
  live.clear();
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function tempHome(): string {
  const dir = mkdtempSync(join(tmpdir(), "thru-alias-home-"));
  tempDirs.push(dir);
  return dir;
}

function lines(text: string): string[] {
  return text.split(/\r?\n/).filter((l) => l.length > 0);
}

async function collect(stream: ReadableStream<Uint8Array> | null, sink: Uint8Array[]): Promise<void> {
  if (!stream) return;
  const reader = stream.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return;
      sink.push(value);
    }
  } catch {
    // pipe closed by kill
  }
}

// A route is a first argument that is neither a flag nor a command word. Routes play through
// the monitors, so they get a quiet --gain unless one is given explicitly.
function isRoute(args: string[]): boolean {
  return args.length > 0 && !args[0].startsWith("-") && !COMMAND_WORDS.has(args[0]) && !args.includes("--gain");
}

function start(args: string[], env: Record<string, string> = {}): Run {
  const spawnedAt = performance.now();
  const finalArgs = isRoute(args) ? [...args, "--gain", process.env.THRU_GAIN ?? "0.05"] : args;
  const proc = Bun.spawn([BIN, ...finalArgs], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, ...env } as Record<string, string>,
  });
  live.add(proc);
  const outChunks: Uint8Array[] = [];
  const errChunks: Uint8Array[] = [];
  const drained = Promise.all([
    collect(proc.stdout as ReadableStream<Uint8Array>, outChunks),
    collect(proc.stderr as ReadableStream<Uint8Array>, errChunks),
  ]).then(() => undefined);
  return {
    proc,
    spawnedAt,
    drained,
    out: () => Buffer.concat(outChunks).toString("utf8"),
    err: () => Buffer.concat(errChunks).toString("utf8"),
  };
}

async function exitWithin(proc: Bun.Subprocess, ms: number): Promise<number | null> {
  return Promise.race([proc.exited, Bun.sleep(ms).then(() => null)]);
}

async function waitForLine(r: Run, re: RegExp, timeoutMs: number): Promise<RegExpMatchArray | null> {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    const m = r.out().match(re);
    if (m) return m;
    if (performance.now() >= deadline) return null;
    await Bun.sleep(20);
  }
}

// Sends a signal, waits for exit and for stdout to drain. Returns the exit code (null on timeout).
async function interrupt(r: Run, signal: "SIGINT" | "SIGTERM" = "SIGINT"): Promise<number | null> {
  r.proc.kill(signal);
  const code = await exitWithin(r.proc, 5000);
  await Promise.race([r.drained, Bun.sleep(2000)]);
  return code;
}

async function runToEnd(
  args: string[],
  env: Record<string, string> = {},
  timeoutMs = 10_000,
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const r = start(args, env);
  const code = await exitWithin(r.proc, timeoutMs);
  if (code === null) {
    r.proc.kill("SIGKILL");
  }
  await Promise.race([r.drained, Bun.sleep(2000)]);
  return { code, stdout: r.out(), stderr: r.err() };
}

// Runs `thru alias ...` against the given temp HOME.
async function alias(home: string, args: string[]) {
  return runToEnd(["alias", ...args], { HOME: home });
}

async function addAlias(home: string, name: string, device: string, channels?: string): Promise<void> {
  const args = ["add", name, device];
  if (channels !== undefined) args.push("--channels", channels);
  const r = await alias(home, args);
  if (r.code !== 0) throw new Error(`alias add ${name} exited ${r.code}: ${r.stderr}`);
}

function aliasesPath(home: string): string {
  return join(home, ".config", "thru", "aliases.json");
}

// ---------------------------------------------------------------------------
// Pure tests: no audio routing, always run.
// ---------------------------------------------------------------------------

describe("alias add / list / rm", () => {
  test("add, list, rm round trip prints exact stdout lines", async () => {
    const home = tempHome();

    const add = await alias(home, ["add", "qc", FAKE_DEVICE, "--channels", "3-4"]);
    expect(add.code).toBe(0);
    expect(lines(add.stdout)).toEqual([`thru: alias qc -> ${FAKE_DEVICE} (channels 3-4)`]);

    const list = await alias(home, ["list"]);
    expect(list.code).toBe(0);
    expect(lines(list.stdout)).toEqual([`qc -> ${FAKE_DEVICE} (channels 3-4) [not connected]`]);

    const rm = await alias(home, ["rm", "qc"]);
    expect(rm.code).toBe(0);
    expect(lines(rm.stdout)).toEqual(["thru: alias qc removed"]);

    const empty = await alias(home, []);
    expect(empty.code).toBe(0);
    expect(lines(empty.stdout)).toEqual(["thru: no aliases"]);
  });

  test("add without channels omits the channels clause", async () => {
    const home = tempHome();
    const add = await alias(home, ["add", "af", FAKE_DEVICE]);
    expect(add.code).toBe(0);
    expect(lines(add.stdout)).toEqual([`thru: alias af -> ${FAKE_DEVICE}`]);

    const list = await alias(home, []);
    expect(lines(list.stdout)).toEqual([`af -> ${FAKE_DEVICE} [not connected]`]);
  });

  test("list is sorted by name", async () => {
    const home = tempHome();
    await addAlias(home, "qc", FAKE_DEVICE, "3-4");
    await addAlias(home, "af", FAKE_DEVICE_2, "1-2");

    const list = await alias(home, []);
    expect(list.code).toBe(0);
    const names = lines(list.stdout).map((l) => l.split(" -> ")[0]);
    expect(names).toEqual(["af", "qc"]);
  });

  test("replacing an alias prints updated", async () => {
    const home = tempHome();
    const first = await alias(home, ["add", "qc", FAKE_DEVICE]);
    expect(lines(first.stdout)).toEqual([`thru: alias qc -> ${FAKE_DEVICE}`]);

    const second = await alias(home, ["add", "qc", FAKE_DEVICE_2, "--channels", "1-2"]);
    expect(second.code).toBe(0);
    expect(lines(second.stdout)).toEqual([`thru: alias qc updated -> ${FAKE_DEVICE_2} (channels 1-2)`]);
  });

  test("rm of an unknown alias exits 2 with no alias on stderr", async () => {
    const home = tempHome();
    const r = await alias(home, ["rm", "nope"]);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("thru: no alias 'nope'");
  });

  test("alias with none defined prints thru: no aliases and exits 0", async () => {
    const home = tempHome();
    const r = await alias(home, []);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("thru: no aliases");
  });
});

describe("alias names", () => {
  test("name is stored lowercase and matched case-insensitively", async () => {
    const home = tempHome();

    const add = await alias(home, ["add", "QC", FAKE_DEVICE, "--channels", "1-2"]);
    expect(add.code).toBe(0);
    expect(lines(add.stdout)).toEqual([`thru: alias qc -> ${FAKE_DEVICE} (channels 1-2)`]);

    const saved = JSON.parse(readFileSync(aliasesPath(home), "utf8"));
    expect(Object.keys(saved)).toEqual(["qc"]);

    const list = await alias(home, []);
    expect(lines(list.stdout)[0].startsWith("qc -> ")).toBe(true);

    // Adding under a different case replaces the same alias.
    const replace = await alias(home, ["add", "qc", FAKE_DEVICE_2]);
    expect(replace.code).toBe(0);
    expect(replace.stdout).toContain("updated");

    // Removing under a different case removes it.
    const rm = await alias(home, ["rm", "QC"]);
    expect(rm.code).toBe(0);
    expect(rm.stdout).toMatch(/^thru: alias qc removed\r?$/mi);

    const empty = await alias(home, []);
    expect(empty.stdout).toContain("thru: no aliases");
  });

  const badNames: Array<{ label: string; name: string }> = [
    { label: "leading dash", name: "-qc" },
    { label: "space", name: "my qc" },
    { label: "command word list", name: "list" },
    { label: "command word alias", name: "alias" },
    { label: "command word inspect", name: "inspect" },
    { label: "command word map-check", name: "map-check" },
    { label: "command word help", name: "help" },
    { label: "empty", name: "" },
  ];

  for (const c of badNames) {
    test(`${c.label} (${JSON.stringify(c.name)}) exits 1 with bad alias name on stderr`, async () => {
      const home = tempHome();
      const r = await alias(home, ["add", c.name, FAKE_DEVICE]);
      expect(r.code).toBe(1);
      expect(r.stderr).toMatch(/^thru: bad alias name:/m);
    });
  }
});

describe("alias channels", () => {
  const badChannels = ["3-", "0", "4-3", "a", ""];

  for (const spec of badChannels) {
    test(`--channels ${JSON.stringify(spec)} exits 3 with bad channels on stderr`, async () => {
      const home = tempHome();
      const r = await alias(home, ["add", "qc", FAKE_DEVICE, "--channels", spec]);
      expect(r.code).toBe(3);
      expect(r.stderr).toMatch(/^thru: bad channels:/m);
    });
  }
});

describe("alias device matching", () => {
  test("adding an alias for a device that does not exist prints the note and still saves with exit 0", async () => {
    const home = tempHome();
    const r = await alias(home, ["add", "ghost", MISSING_IN]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain(`thru: note: no device currently matches '${MISSING_IN}'`);

    const saved = JSON.parse(readFileSync(aliasesPath(home), "utf8"));
    expect(saved).toHaveProperty("ghost");
  });

  test("list state is not connected for a device that does not exist", async () => {
    const home = tempHome();
    await addAlias(home, "ghost", MISSING_IN);

    const r = await alias(home, []);
    expect(r.code).toBe(0);
    expect(lines(r.stdout)).toEqual([`ghost -> ${MISSING_IN} [not connected]`]);
  });

  test("--json is an array of {name, device, channels, state}", async () => {
    const home = tempHome();
    await addAlias(home, "qc", FAKE_DEVICE, "3-4");
    await addAlias(home, "af", FAKE_DEVICE_2);

    const r = await alias(home, ["--json"]);
    expect(r.code).toBe(0);
    const arr = JSON.parse(r.stdout);
    expect(Array.isArray(arr)).toBe(true);
    expect(arr).toHaveLength(2);

    const qc = arr.find((a: { name: string }) => a.name === "qc");
    expect(qc).toEqual({ name: "qc", device: FAKE_DEVICE, channels: "3-4", state: "not connected" });

    const af = arr.find((a: { name: string }) => a.name === "af");
    for (const key of ["name", "device", "state"]) {
      expect(af).toHaveProperty(key);
    }
    expect(af.device).toBe(FAKE_DEVICE_2);
    expect(af.channels ?? null).toBeNull();
  });

  test("persisted aliases.json is valid JSON with the documented shape", async () => {
    const home = tempHome();
    await addAlias(home, "qc", FAKE_DEVICE, "3-4");
    await addAlias(home, "af", FAKE_DEVICE_2);

    expect(existsSync(aliasesPath(home))).toBe(true);
    const saved = JSON.parse(readFileSync(aliasesPath(home), "utf8"));
    expect(Object.keys(saved).sort()).toEqual(["af", "qc"]);
    expect(saved.qc).toEqual({ device: FAKE_DEVICE, channels: "3-4" });
    expect(saved.af.device).toBe(FAKE_DEVICE_2);
    expect(saved.af.channels ?? null).toBeNull();
  });

  test("route using an alias for a missing device with --no-wait exits 2 and names the device specifier", async () => {
    const home = tempHome();
    await addAlias(home, "ghost", MISSING_IN);

    const r = await runToEnd(["ghost", MISSING_OUT, "--no-wait"], { HOME: home });
    expect(r.code).toBe(2);
    expect(r.stderr).toContain(MISSING_IN);
    expect(r.stderr).not.toMatch(/fatal error|panic|segmentation fault|unhandled/i);
    expect(r.stdout).not.toContain("thru: connected");
  });
});

// ---------------------------------------------------------------------------
// Hardware tests: only with THRU_HW=1. Do not run without audio hardware.
// ---------------------------------------------------------------------------

describe.skipIf(!HW)("alias hardware", () => {
  test("qc and af route with their channels: connected line shows map=3-4:1-2 and real device names", async () => {
    const home = tempHome();
    await addAlias(home, "qc", IN_TEXT, "3-4");
    await addAlias(home, "af", OUT_TEXT, "1-2");

    const r = start(["qc", "af", "--no-wait", "--gain", "0.05"], { HOME: home });
    const m = await waitForLine(r, CONNECTED_RE, 10_000);
    expect(m).not.toBeNull();
    expect(m?.[3]).toBe("3-4:1-2");
    expect(m?.[1]?.toLowerCase()).toContain(IN_TEXT.toLowerCase());
    expect(m?.[2]?.toLowerCase()).toContain(OUT_TEXT.toLowerCase());
    expect(m?.[1]).not.toBe("qc");
    expect(m?.[2]).not.toBe("af");
    expect(await interrupt(r)).toBe(0);
  }, 30_000);

  test("alias list shows connected for both aliases", async () => {
    const home = tempHome();
    await addAlias(home, "qc", IN_TEXT, "3-4");
    await addAlias(home, "af", OUT_TEXT, "1-2");

    const r = await alias(home, []);
    expect(r.code).toBe(0);
    const ls = lines(r.stdout);
    const qcLine = ls.find((l) => l.startsWith("qc -> "));
    const afLine = ls.find((l) => l.startsWith("af -> "));
    expect(qcLine).toMatch(/\(channels 3-4\) \[connected: .+\]$/);
    expect(afLine).toMatch(/\(channels 1-2\) \[connected: .+\]$/);
  }, 20_000);

  test("--map 1-2:1-2 overrides alias channels", async () => {
    const home = tempHome();
    await addAlias(home, "qc", IN_TEXT, "3-4");
    await addAlias(home, "af", OUT_TEXT, "1-2");

    const r = start(["qc", "af", "--no-wait", "--gain", "0.05", "--map", "1-2:1-2"], { HOME: home });
    const m = await waitForLine(r, CONNECTED_RE, 10_000);
    expect(m).not.toBeNull();
    expect(m?.[3]).toBe("1-2:1-2");
    expect(await interrupt(r)).toBe(0);
  }, 30_000);

  test("only the input alias has channels: map is 3-4:1-2 with the output given as device text", async () => {
    const home = tempHome();
    await addAlias(home, "qc", IN_TEXT, "3-4");

    const r = start(["qc", OUT_TEXT, "--no-wait", "--gain", "0.05"], { HOME: home });
    const m = await waitForLine(r, CONNECTED_RE, 10_000);
    expect(m).not.toBeNull();
    expect(m?.[3]).toBe("3-4:1-2");
    expect(await interrupt(r)).toBe(0);
  }, 30_000);

  test("after one successful run last.json stores the alias texts and bare thru reconnects", async () => {
    const home = tempHome();
    await addAlias(home, "qc", IN_TEXT, "3-4");
    await addAlias(home, "af", OUT_TEXT, "1-2");

    const first = start(["qc", "af", "--no-wait", "--gain", "0.05"], { HOME: home });
    const m1 = await waitForLine(first, CONNECTED_RE, 10_000);
    expect(m1).not.toBeNull();
    expect(await interrupt(first)).toBe(0);

    const savedPath = join(home, ".config", "thru", "last.json");
    expect(existsSync(savedPath)).toBe(true);
    const saved = JSON.parse(readFileSync(savedPath, "utf8"));
    expect(saved).toHaveProperty("inputText", "qc");
    expect(saved).toHaveProperty("outputText", "af");

    const second = start([], { HOME: home });
    const m2 = await waitForLine(second, CONNECTED_RE, 5000);
    expect(m2).not.toBeNull();
    expect(m2?.[1]).toBe(m1?.[1] ?? "");
    expect(m2?.[2]).toBe(m1?.[2] ?? "");
    expect(m2?.[3]).toBe(m1?.[3] ?? "");
    expect(await interrupt(second)).toBe(0);
  }, 40_000);
});
