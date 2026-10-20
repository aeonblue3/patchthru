// Phase 1 black-box contract tests for the `thru` CLI.
// Spec: docs/specs/cli-spec.md. Drives the compiled binary via Bun.spawn only.
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = process.env.THRU_BIN ?? new URL("../.build/release/thru", import.meta.url).pathname;
const ISOLATED_HOME = mkdtempSync(join(tmpdir(), "thru-test-home-")); // never touch the real ~/.config/thru
const HW = process.env.THRU_HW === "1";
const IN_TEXT = process.env.THRU_IN ?? "quad cortex";
const OUT_TEXT = process.env.THRU_OUT ?? "audiofuse";

const MISSING_IN = "zz-no-such-input-device";
const MISSING_OUT = "zz-no-such-output-device";

const CONNECTED_RE =
  /^thru: connected (.+?) -> (.+?) map=(\S+) buffer=(\d+) first-audio=(\d+(?:\.\d+)?)ms\r?$/m;
const METER_RE = /^thru: meter in=\S+ out=\S+\r?$/gm;

interface Device {
  name: string;
  uid: string;
  inputs: number;
  outputs: number;
  rate: number;
  bufferFrames: number;
  alive: boolean;
  aggregate: boolean;
}

interface Run {
  proc: Bun.Subprocess;
  spawnedAt: number;
  drained: Promise<void>;
  out: () => string;
  outBytes: () => Buffer;
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
  const dir = mkdtempSync(join(tmpdir(), "thru-home-"));
  tempDirs.push(dir);
  return dir;
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

function start(args: string[], env: Record<string, string> = {}): Run {
  const spawnedAt = performance.now();
  // Real routes play through the monitors: keep hardware tests quiet unless a gain is given explicitly.
  const isRoute = args[0] === IN_TEXT && !args.includes("--gain");
  const finalArgs = isRoute ? [...args, "--gain", process.env.THRU_GAIN ?? "0.05"] : args;
  const proc = Bun.spawn([BIN, ...finalArgs], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, HOME: ISOLATED_HOME, ...env } as Record<string, string>,
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
    outBytes: () => Buffer.concat(outChunks),
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
): Promise<{ code: number | null; stdout: string; stderr: string; stdoutBytes: Buffer }> {
  const r = start(args, env);
  const code = await exitWithin(r.proc, timeoutMs);
  if (code === null) {
    r.proc.kill("SIGKILL");
  }
  await Promise.race([r.drained, Bun.sleep(2000)]);
  return { code, stdout: r.out(), stderr: r.err(), stdoutBytes: r.outBytes() };
}

async function listDevices(): Promise<Device[]> {
  const r = await runToEnd(["list", "--json"]);
  if (r.code !== 0) throw new Error(`list --json exited ${r.code}: ${r.stderr}`);
  return JSON.parse(r.stdout) as Device[];
}

async function expectNoThruAggregates(): Promise<void> {
  const leftovers = (await listDevices())
    .filter((d) => d.name.startsWith("thru"))
    .map((d) => d.name);
  expect(leftovers).toEqual([]);
}

// ---------------------------------------------------------------------------
// Pure tests: no audio routing, always run.
// ---------------------------------------------------------------------------

describe("list", () => {
  test("list exits 0", async () => {
    const r = await runToEnd(["list"]);
    expect(r.code).toBe(0);
  });

  test("list --json parses to an array of device objects with the contract keys", async () => {
    const r = await runToEnd(["list", "--json"]);
    expect(r.code).toBe(0);
    const devices = JSON.parse(r.stdout);
    expect(Array.isArray(devices)).toBe(true);
    for (const d of devices) {
      expect(typeof d).toBe("object");
      expect(d).not.toBeNull();
      for (const key of ["name", "uid", "inputs", "outputs", "rate", "bufferFrames", "alive", "aggregate"]) {
        expect(d).toHaveProperty(key);
      }
    }
  });
});

describe("map-check valid specs", () => {
  const validCases: Array<{ spec: string; inCh: number; outCh: number; pairs: Array<[number, number]> }> = [
    { spec: "3-4:1-2", inCh: 8, outCh: 18, pairs: [[3, 1], [4, 2]] },
    { spec: "1:1-2", inCh: 4, outCh: 8, pairs: [[1, 1], [1, 2]] },
    { spec: "1,3:5,6", inCh: 4, outCh: 8, pairs: [[1, 5], [3, 6]] },
    { spec: "1-2:7,8", inCh: 2, outCh: 8, pairs: [[1, 7], [2, 8]] },
  ];

  for (const c of validCases) {
    test(`${c.spec} with ${c.inCh} in / ${c.outCh} out resolves to pairs`, async () => {
      const r = await runToEnd(["map-check", c.spec, String(c.inCh), String(c.outCh)]);
      expect(r.code).toBe(0);
      const obj = JSON.parse(r.stdout);
      expect(obj).toEqual({
        pairs: c.pairs.map(([input, output]) => ({ input, output })),
      });
    });
  }
});

describe("map-check invalid specs", () => {
  const invalidCases: Array<{ label: string; spec: string; inCh: number; outCh: number }> = [
    { label: "channel above input count", spec: "5:1", inCh: 4, outCh: 4 },
    { label: "count mismatch", spec: "1-2:1", inCh: 4, outCh: 4 },
    { label: "duplicate output channel", spec: "1-2:3,3", inCh: 4, outCh: 4 },
    { label: "channel zero", spec: "0:1", inCh: 4, outCh: 4 },
    { label: "non-numeric", spec: "a:b", inCh: 4, outCh: 4 },
    { label: "empty spec", spec: "", inCh: 4, outCh: 4 },
    { label: "missing colon", spec: "1-2", inCh: 4, outCh: 4 },
    { label: "reversed range", spec: "4-3:1-2", inCh: 4, outCh: 4 },
  ];

  for (const c of invalidCases) {
    test(`${c.label} (${JSON.stringify(c.spec)}) exits 3 with bad map on stderr`, async () => {
      const r = await runToEnd(["map-check", c.spec, String(c.inCh), String(c.outCh)]);
      expect(r.code).toBe(3);
      expect(r.stderr).toMatch(/^thru: bad map:/);
    });
  }
});

describe("unknown devices", () => {
  test("with --no-wait exits 2", async () => {
    const r = await runToEnd([MISSING_IN, MISSING_OUT, "--no-wait"]);
    expect(r.code).toBe(2);
  });

  test("without --no-wait prints waiting lines, keeps running, and SIGINT prints stopped and exits 0", async () => {
    const r = start([MISSING_IN, MISSING_OUT]);

    const inWaiting = await waitForLine(r, /^thru: waiting for 'zz-no-such-input-device'\r?$/m, 1500);
    expect(inWaiting).not.toBeNull();
    const outWaiting = await waitForLine(r, /^thru: waiting for 'zz-no-such-output-device'\r?$/m, 1500);
    expect(outWaiting).not.toBeNull();

    await Bun.sleep(500);
    expect(r.proc.exitCode).toBeNull();

    const code = await interrupt(r, "SIGINT");
    expect(code).toBe(0);
    expect(r.out()).toContain("thru: stopped");
  }, 15_000);
});

describe("no arguments", () => {
  test("with no saved route prints usage and exits 1", async () => {
    const home = tempHome();
    const r = await runToEnd([], { HOME: home });
    expect(r.code).toBe(1);
    expect(r.stdout + r.stderr).toMatch(/usage/i);
  });
});

// ---------------------------------------------------------------------------
// Hardware tests: only with THRU_HW=1. Do not run without audio hardware.
// ---------------------------------------------------------------------------

const STUDIO_PRESENT =
  HW &&
  (await listDevices()
    .then((ds) => ds.some((d) => d.name.toLowerCase().includes("studio")))
    .catch(() => false));

describe.skipIf(!HW)("hardware", () => {
  test("connected line appears within 1000 ms with first-audio under 600 ms", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"]);
    const m = await waitForLine(r, CONNECTED_RE, 1000);
    const elapsed = performance.now() - r.spawnedAt;
    expect(m).not.toBeNull();
    expect(elapsed).toBeLessThan(1000);
    expect(Number(m?.[5])).toBeLessThan(600);
    expect(await interrupt(r)).toBe(0);
  }, 20_000);

  test("SIGINT prints stopped, exits 0, and leaves no thru aggregate", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"]);
    expect(await waitForLine(r, CONNECTED_RE, 1000)).not.toBeNull();
    const code = await interrupt(r, "SIGINT");
    expect(code).toBe(0);
    expect(r.out()).toContain("thru: stopped");
    await expectNoThruAggregates();
  }, 20_000);

  test("SIGKILL leaves no thru aggregate after 1.5 s", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"]);
    expect(await waitForLine(r, CONNECTED_RE, 1000)).not.toBeNull();
    r.proc.kill("SIGKILL");
    await r.proc.exited;
    await Bun.sleep(1500);
    await expectNoThruAggregates();
  }, 20_000);

  test.skipIf(!STUDIO_PRESENT)("inspect Studio is byte-identical before and after a route run", async () => {
    const before = await runToEnd(["inspect", "Studio"]);
    expect(before.code).toBe(0);

    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"]);
    expect(await waitForLine(r, CONNECTED_RE, 1000)).not.toBeNull();
    expect(await interrupt(r)).toBe(0);

    const after = await runToEnd(["inspect", "Studio"]);
    expect(after.code).toBe(0);
    expect(Buffer.compare(after.stdoutBytes, before.stdoutBytes)).toBe(0);
  }, 30_000);

  test("--meter prints thru: meter in=... out=... lines", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait", "--meter"]);
    const countMeters = () => (r.out().match(METER_RE) ?? []).length;
    const deadline = performance.now() + 4000;
    while (countMeters() < 2 && performance.now() < deadline) {
      await Bun.sleep(50);
    }
    expect(countMeters()).toBeGreaterThanOrEqual(2);
    expect(await interrupt(r)).toBe(0);
  }, 20_000);

  test("saved route: no-arg thru reconnects to the same devices", async () => {
    const home = tempHome();

    const first = start([IN_TEXT, OUT_TEXT, "--no-wait"], { HOME: home });
    const m1 = await waitForLine(first, CONNECTED_RE, 1000);
    expect(m1).not.toBeNull();
    expect(await interrupt(first)).toBe(0);

    const savedPath = join(home, ".config", "thru", "last.json");
    expect(existsSync(savedPath)).toBe(true);
    const saved = JSON.parse(readFileSync(savedPath, "utf8"));
    expect(saved).toHaveProperty("inputText", IN_TEXT);
    expect(saved).toHaveProperty("outputText", OUT_TEXT);

    const second = start([], { HOME: home });
    const m2 = await waitForLine(second, CONNECTED_RE, 3000);
    expect(m2).not.toBeNull();
    expect(m2?.[1]).toBe(m1?.[1] ?? "");
    expect(m2?.[2]).toBe(m1?.[2] ?? "");
    expect(m2?.[3]).toBe(m1?.[3] ?? "");
    expect(await interrupt(second)).toBe(0);
  }, 30_000);
});
