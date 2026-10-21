// Meter contract tests for `thru --meter` and `thru meter-snapshot`.
// Spec: docs/specs/meter-spec.md. Drives the compiled binary via Bun.spawn only.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = process.env.THRU_BIN ?? new URL("../.build/release/thru", import.meta.url).pathname;
const ISOLATED_HOME = mkdtempSync(join(tmpdir(), "thru-meter-home-")); // never touch the real ~/.config/thru
const HW = process.env.THRU_HW === "1";
const IN_TEXT = process.env.THRU_IN ?? "quad cortex";
const OUT_TEXT = process.env.THRU_OUT ?? "audiofuse";
const GAIN = process.env.THRU_GAIN ?? "0.05";

const MISSING_IN = "zz-no-such-input-device";
const MISSING_OUT = "zz-no-such-output-device";

const ESC = "\u001b";
const ALT_ON = "\u001b[?1049h";
const ALT_OFF = "\u001b[?1049l";
const CURSOR_HIDE = "\u001b[?25l";
const CURSOR_SHOW = "\u001b[?25h";
const ANSI_RE = /\u001b\[[0-9;?]*[ -\/]*[@-~]/g;
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

afterAll(() => {
  rmSync(ISOLATED_HOME, { recursive: true, force: true });
});

function tempHome(): string {
  const dir = mkdtempSync(join(tmpdir(), "thru-meter-tmp-"));
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

// Spawns any command with tracked, drained stdout/stderr. Used for BIN and for `script`.
function spawnTracked(cmd: string[], env: Record<string, string>, stdin: "ignore" | "pipe" = "ignore"): Run {
  const spawnedAt = performance.now();
  const proc = Bun.spawn(cmd, {
    stdin,
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

// Real routes play through the monitors: keep hardware tests quiet unless a gain is given explicitly.
function start(args: string[], env: Record<string, string> = {}): Run {
  const isRoute = args[0] === IN_TEXT && !args.includes("--gain");
  const finalArgs = isRoute ? [...args, "--gain", GAIN] : args;
  return spawnTracked([BIN, ...finalArgs], env);
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
// Frame helpers.
// ---------------------------------------------------------------------------

// Splits a rendered frame into lines, dropping only the final newline.
function frameLines(stdout: string): string[] {
  return stdout.replace(/\r?\n$/, "").split(/\r?\n/);
}

function plain(line: string): string {
  return line.replace(ANSI_RE, "");
}

function displayWidth(line: string): number {
  return [...plain(line)].length;
}

// Finds the row whose label starts the line, e.g. "OUT 1" but not "OUT 10".
function findRow(lines: string[], label: string): string | undefined {
  const re = new RegExp(`^\\s*${label}\\s`);
  return lines.find((l) => re.test(plain(l)));
}

function filledCells(line: string): number {
  return (plain(line).match(/█/g) ?? []).length;
}

// Bar cells for a level in a bar of B cells, per the spec formula.
function expectedCells(db: number, bar: number): number {
  const clamped = Math.min(0, Math.max(-60, db));
  return Math.round(((clamped + 60) / 60) * bar);
}

async function snapshot(w: number, h: number, levels: string, extra: string[] = []) {
  return runToEnd(["meter-snapshot", String(w), String(h), levels, ...extra]);
}

// ---------------------------------------------------------------------------
// Pure tests: no audio routing, always run.
// ---------------------------------------------------------------------------

describe("meter-snapshot: size contract", () => {
  const sizes: Array<[number, number]> = [
    [50, 10],
    [80, 24],
    [120, 40],
  ];

  for (const [w, h] of sizes) {
    for (const color of [false, true]) {
      test(`${w}x${h} color=${color}: exit 0, at most ${h} lines, every line within ${w} columns`, async () => {
        const r = await snapshot(w, h, "-9.3,-30,-60,0.2", ["--inputs", "-20,-40", ...(color ? ["--color"] : [])]);
        expect(r.code).toBe(0);
        const lines = frameLines(r.stdout);
        expect(lines.length).toBeLessThanOrEqual(h);
        for (const line of lines) {
          expect(displayWidth(line)).toBeLessThanOrEqual(w);
        }
      });
    }
  }
});

describe("meter-snapshot: color", () => {
  test("without --color the output has no ESC character at all", async () => {
    const r = await snapshot(80, 24, "-10,-20,-30");
    expect(r.code).toBe(0);
    expect(r.stdout.includes(ESC)).toBe(false);
  });

  test("with --color the output contains some ESC", async () => {
    const r = await snapshot(80, 24, "-10,-20,-30", ["--color"]);
    expect(r.code).toBe(0);
    expect(r.stdout.includes(ESC)).toBe(true);
  });
});

describe("meter-snapshot: labels and readouts", () => {
  test("OUT 1..n labels are present", async () => {
    const r = await snapshot(80, 24, "-10,-20,-30");
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout);
    for (const label of ["OUT 1", "OUT 2", "OUT 3"]) {
      expect(findRow(lines, label)).toBeDefined();
    }
  });

  test("a -9.3 level prints -9.3 dB on its row", async () => {
    const r = await snapshot(80, 24, "-9.3");
    expect(r.code).toBe(0);
    const row = findRow(frameLines(r.stdout), "OUT 1");
    expect(row).toBeDefined();
    expect(plain(row ?? "")).toContain("-9.3 dB");
  });

  test("levels at or below -60 print -inf dB", async () => {
    const r = await snapshot(80, 24, "-60,-75");
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout);
    expect(plain(findRow(lines, "OUT 1") ?? "")).toContain("-inf dB");
    expect(plain(findRow(lines, "OUT 2") ?? "")).toContain("-inf dB");
  });

  test("help row contains q quit", async () => {
    const r = await snapshot(80, 24, "-10");
    expect(r.code).toBe(0);
    expect(frameLines(r.stdout).some((l) => plain(l).includes("q quit"))).toBe(true);
  });
});

describe("meter-snapshot: bar length", () => {
  const W = 80;
  const B = W - 36; // label 9 + readout 21 + clip 6 are fixed; the rest is bar

  test("filled cells increase with level and match round((dB+60)/60*B) within one cell", async () => {
    const levels = [-45, -30, -9.3, -1];
    const r = await snapshot(W, 24, levels.join(","));
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout);

    const counts = levels.map((_, i) => {
      const row = findRow(lines, `OUT ${i + 1}`);
      expect(row).toBeDefined();
      return filledCells(row ?? "");
    });

    for (let i = 0; i < levels.length; i++) {
      expect(Math.abs(counts[i] - expectedCells(levels[i], B))).toBeLessThanOrEqual(1);
      if (i > 0) expect(counts[i]).toBeGreaterThan(counts[i - 1]);
    }
  });
});

describe("meter-snapshot: clip", () => {
  test("a level >= 0 shows CLIP on that row only", async () => {
    const r = await snapshot(80, 24, "-3,0.5");
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout);
    const out1 = findRow(lines, "OUT 1");
    const out2 = findRow(lines, "OUT 2");
    expect(out1).toBeDefined();
    expect(out2).toBeDefined();
    expect(plain(out1 ?? "")).not.toContain("CLIP");
    expect(plain(out2 ?? "")).toContain("CLIP");
  });
});

describe("meter-snapshot: inputs", () => {
  test("--inputs adds IN rows above the OUT rows", async () => {
    const r = await snapshot(80, 24, "-10,-20", ["--inputs", "-15,-25"]);
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout).map(plain);
    const in1 = lines.findIndex((l) => /^\s*IN 1\s/.test(l));
    const in2 = lines.findIndex((l) => /^\s*IN 2\s/.test(l));
    const out1 = lines.findIndex((l) => /^\s*OUT 1\s/.test(l));
    expect(in1).toBeGreaterThanOrEqual(0);
    expect(in2).toBeGreaterThanOrEqual(0);
    expect(out1).toBeGreaterThan(in2);
  });

  test("without --inputs there are no IN rows", async () => {
    const r = await snapshot(80, 24, "-10,-20");
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout).map(plain);
    expect(lines.some((l) => /^\s*IN \d/.test(l))).toBe(false);
  });
});

describe("meter-snapshot: too small", () => {
  for (const [w, h] of [
    [49, 20],
    [80, 9],
  ] as Array<[number, number]>) {
    test(`${w}x${h} prints exactly the too-small line`, async () => {
      const r = await snapshot(w, h, "-10,-20");
      expect(r.code).toBe(0);
      expect(frameLines(r.stdout)).toEqual(["terminal too small (need 50x10)"]);
    });
  }
});

describe("meter-snapshot: small height", () => {
  test("10 rows with 4 channels: help row is dropped first, every OUT row is kept", async () => {
    const r = await snapshot(80, 10, "-10,-20,-30,-40");
    expect(r.code).toBe(0);
    const lines = frameLines(r.stdout);
    expect(lines.length).toBeLessThanOrEqual(10);
    for (let i = 1; i <= 4; i++) {
      expect(findRow(lines, `OUT ${i}`)).toBeDefined();
    }
    // Help is the first thing sacrificed when rows run short.
    expect(lines.some((l) => plain(l).includes("q quit"))).toBe(false);
  });

  test("more levels than fit does not crash and stays within height", async () => {
    const levels = Array.from({ length: 12 }, (_, i) => String(-5 - i * 3)).join(",");
    const r = await snapshot(80, 10, levels);
    expect(r.code).toBe(0);
    expect(frameLines(r.stdout).length).toBeLessThanOrEqual(10);
    expect(r.stderr).not.toMatch(/fatal error|panic|segmentation fault|unhandled/i);
  });
});

// ---------------------------------------------------------------------------
// Plain fallback: stdout is a pipe, so the one-line meter events print instead.
// ---------------------------------------------------------------------------

describe("--meter plain fallback", () => {
  test("--meter with a pipe and an unknown device exits 2 and writes no alternate-screen or ESC output", async () => {
    const r = await runToEnd([MISSING_IN, MISSING_OUT, "--no-wait", "--meter"]);
    expect(r.code).toBe(2);
    expect(r.stdout.includes(ESC)).toBe(false);
    expect(r.stdout.includes(ALT_ON)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Hardware tests: only with THRU_HW=1. Do not run without audio hardware.
// ---------------------------------------------------------------------------

describe.skipIf(!HW)("meter hardware", () => {
  test("--meter on a pipe prints thru: meter lines and no alternate screen", async () => {
    const r = start([IN_TEXT, OUT_TEXT, "--no-wait", "--meter"]);
    expect(await waitForLine(r, METER_RE, 3000)).not.toBeNull();
    await Bun.sleep(3000);
    expect(await interrupt(r)).toBe(0);
    expect((r.out().match(METER_RE) ?? []).length).toBeGreaterThanOrEqual(1);
    expect(r.out().includes(ALT_ON)).toBe(false);
  }, 30_000);

  test("--meter under a pseudo-terminal enters and restores the screen and stops cleanly", async () => {
    const home = tempHome();
    // stdin stays open as a pipe so `script` does not see EOF and exit early.
    const run = spawnTracked(
      ["script", "-q", "/dev/null", BIN, IN_TEXT, OUT_TEXT, "--meter", "--gain", GAIN],
      { HOME: home },
      "pipe",
    );
    try {
      await Bun.sleep(3000);

      // Signal the thru process itself (a child of `script`), not `script`.
      const pgrep = Bun.spawn(["pgrep", "-P", String(run.proc.pid)], { stdout: "pipe", stderr: "ignore" });
      const pids = (await new Response(pgrep.stdout).text())
        .split(/\s+/)
        .filter(Boolean)
        .map(Number);
      await pgrep.exited;
      expect(pids.length).toBeGreaterThan(0);
      for (const pid of pids) {
        process.kill(pid, "SIGINT");
      }

      await exitWithin(run.proc, 5000);
      await Promise.race([run.drained, Bun.sleep(2000)]);
    } finally {
      try {
        run.proc.kill("SIGKILL");
      } catch {
        // already exited
      }
    }

    // Normalize pty line endings before matching.
    const text = run.out().replace(/\r\n/g, "\n");
    expect(text.includes(ALT_ON)).toBe(true);
    expect(text.includes(CURSOR_HIDE)).toBe(true);
    expect(text.includes(ALT_OFF)).toBe(true);
    expect(text.includes(CURSOR_SHOW)).toBe(true);
    expect(text.includes("OUT 1")).toBe(true);

    const altOn = text.indexOf(ALT_ON);
    const altOff = text.lastIndexOf(ALT_OFF);
    const showCursor = text.lastIndexOf(CURSOR_SHOW);
    const stopped = text.lastIndexOf("thru: stopped");
    expect(altOn).toBeLessThan(altOff);
    expect(stopped).toBeGreaterThan(altOff);
    expect(stopped).toBeGreaterThan(showCursor);
    expect(text.trimEnd().endsWith("thru: stopped")).toBe(true);

    await expectNoThruAggregates();
  }, 30_000);
});
