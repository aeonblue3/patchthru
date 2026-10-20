// Phase 2 black-box contract tests for the `thru` CLI: watchdog rebuild, unmute holdoff.
// Spec: docs/specs/resilience-spec.md. Drives the compiled binary via Bun.spawn only.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = process.env.THRU_BIN ?? new URL("../.build/release/thru", import.meta.url).pathname;
const ISOLATED_HOME = mkdtempSync(join(tmpdir(), "thru-test-home-")); // never touch the real ~/.config/thru
const HW = process.env.THRU_HW === "1";
const IN_TEXT = process.env.THRU_IN ?? "quad cortex";
const OUT_TEXT = process.env.THRU_OUT ?? "audiofuse";

const CONNECTED_RE =
  /^thru: connected (.+?) -> (.+?) map=(\S+) buffer=(\d+) first-audio=(\d+(?:\.\d+)?)ms\r?$/m;
const CONNECTED_G = new RegExp(CONNECTED_RE.source, "gm");
const DEBUG_REBUILD_RE = /^thru: rebuilding \(debug\)\r?$/m;
const UNMUTED_RE = /^thru: unmuted\r?$/m;
const UNMUTED_G = new RegExp(UNMUTED_RE.source, "gm");

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
  err: () => string;
}

// Every child spawned by a test is registered here and killed in afterEach,
// so no process (and therefore no private aggregate) outlives its test.
const live = new Set<Bun.Subprocess>();

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
});

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
    err: () => Buffer.concat(errChunks).toString("utf8"),
  };
}

async function exitWithin(proc: Bun.Subprocess, ms: number): Promise<number | null> {
  return Promise.race([proc.exited, Bun.sleep(ms).then(() => null)]);
}

// Sends a signal, waits for exit and for stdout to drain. Returns the exit code (null on timeout).
async function interrupt(r: Run, signal: "SIGINT" | "SIGTERM" = "SIGINT"): Promise<number | null> {
  r.proc.kill(signal);
  const code = await exitWithin(r.proc, 5000);
  await Promise.race([r.drained, Bun.sleep(2000)]);
  return code;
}

// Polls until the nth match of a global regex has appeared. Returns the performance.now() at
// which it was observed (20 ms granularity), or null on timeout.
async function waitForNth(r: Run, gre: RegExp, n: number, timeoutMs: number): Promise<number | null> {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    const count = (r.out().match(gre) ?? []).length;
    if (count >= n) return performance.now();
    if (performance.now() >= deadline) return null;
    await Bun.sleep(20);
  }
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

describe("absent devices", () => {
  test("a missing device never triggers a rebuild; SIGINT stops cleanly", async () => {
    const r = start(["nosuchdevice", "alsono"]);
    await Bun.sleep(2000);
    expect(r.out()).not.toContain("thru: rebuilding");
    expect(r.proc.exitCode).toBeNull();

    const code = await interrupt(r, "SIGINT");
    expect(code).toBe(0);
    expect(r.out()).toContain("thru: stopped");
  }, 15_000);
});

// ---------------------------------------------------------------------------
// Hardware tests: only with THRU_HW=1. Do not run without audio hardware.
// ---------------------------------------------------------------------------

describe.skipIf(!HW)("phase 2 hardware", () => {
  test("debug rebuild: connected, rebuilding (debug), connected again within 5 s and 1.5 s of the rebuild", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"], { THRU_DEBUG_REBUILD_AFTER: "2" });

    const t1 = await waitForNth(r, CONNECTED_G, 1, 5000);
    expect(t1).not.toBeNull();
    const tRebuild = await waitForNth(r, new RegExp(DEBUG_REBUILD_RE.source, "gm"), 1, 5000);
    expect(tRebuild).not.toBeNull();
    const t2 = await waitForNth(r, CONNECTED_G, 2, 5000);
    expect(t2).not.toBeNull();

    // Line order: connected, rebuilding, connected.
    const text = r.out();
    const firstConnected = text.search(CONNECTED_RE);
    const rebuildIdx = text.search(DEBUG_REBUILD_RE);
    const secondConnected = [...text.matchAll(CONNECTED_G)][1]?.index ?? -1;
    expect(firstConnected).toBeGreaterThanOrEqual(0);
    expect(rebuildIdx).toBeGreaterThan(firstConnected);
    expect(secondConnected).toBeGreaterThan(rebuildIdx);

    expect(Number(t2) - Number(t1)).toBeLessThan(5000);
    expect(Number(t2) - Number(tRebuild)).toBeLessThan(1500);

    const code = await interrupt(r, "SIGINT");
    expect(code).toBe(0);
    expect(r.out()).toContain("thru: stopped");
    await expectNoThruAggregates();
  }, 30_000);

  test("unmute holdoff: no unmuted before the rebuild; unmuted 1.5-4 s after the second connect", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"], { THRU_DEBUG_REBUILD_AFTER: "2" });

    expect(await waitForNth(r, CONNECTED_G, 1, 5000)).not.toBeNull();
    expect(await waitForNth(r, new RegExp(DEBUG_REBUILD_RE.source, "gm"), 1, 5000)).not.toBeNull();

    // The first connect is not held: nothing unmutes before the rebuild line.
    const beforeRebuild = r.out().slice(0, r.out().search(DEBUG_REBUILD_RE));
    expect(beforeRebuild).not.toContain("thru: unmuted");

    const tConnect2 = await waitForNth(r, CONNECTED_G, 2, 5000);
    expect(tConnect2).not.toBeNull();
    const tUnmuted = await waitForNth(r, UNMUTED_G, 1, 8000);
    expect(tUnmuted).not.toBeNull();

    const delta = Number(tUnmuted) - Number(tConnect2);
    expect(delta).toBeGreaterThanOrEqual(1500);
    expect(delta).toBeLessThanOrEqual(4000);

    expect(await interrupt(r, "SIGINT")).toBe(0);
  }, 30_000);

  test("normal run for 3 s: exactly one connected line and no rebuilds", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait"]);
    await Bun.sleep(3000);
    const connectedCount = (r.out().match(CONNECTED_G) ?? []).length;
    expect(connectedCount).toBe(1);
    expect(r.out()).not.toContain("thru: rebuilding");

    expect(await interrupt(r, "SIGINT")).toBe(0);
  }, 20_000);
});
