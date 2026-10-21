# thru: full-screen peak meter (`--meter`)

`--meter` shows a full-screen terminal meter when stdout is a terminal (isatty, `TERM` not `dumb`); otherwise it keeps printing the one-line `thru: meter in=... out=...` event once a second (unchanged, so pipes and tests still work).

## Behavior
- Uses the terminal's alternate screen (`ESC[?1049h` on entry, `ESC[?1049l` on exit), hides the cursor (`ESC[?25l` / `ESC[?25h`), and puts the terminal in non-canonical, no-echo mode (signals stay enabled, so Ctrl-C still sends SIGINT). Everything is restored on every exit path (normal, signal, fatal error); the usual `thru: stopped` line prints after the screen is restored.
- One bar per mapped output channel, measured after gain, labelled with the real output channel number (`OUT 1`, `OUT 2`; a fan-out shows one bar per destination). Bars cover -60 dBFS to 0 dBFS.
- Ballistics (main queue, 30 fps): attack instant, release 24 dB/s. Peak-hold tick holds 1.5 s then falls at 24 dB/s. A clip marker latches when an output sample reaches 0.999 or more, until cleared with `c`.
- Keys: `q` quit (same as Ctrl-C), `c` clear clip markers and holds, `i` toggle input rows. Input rows show the mapped input channels (`IN 3`, `IN 4`) above the outputs; default off.
- Events (`lost`, `restored`, `unmuted`, `rebuilding`, `sleeping`, `woke`, `connected`, `waiting for ...`, `could not connect ...`) do not scroll the screen. They go to a 3-line event area with a `HH:MM:SS` timestamp, newest last. A state word sits above it: `connected`, `muted`, `waiting`, `rebuilding`, `asleep`.
- Before the first connect the header shows the typed device texts and the state is `waiting`; no bars are shown yet because the mapped channels are not known.
- The terminal size is read on every frame, so a resize redraws immediately. `NO_COLOR` set: no colors. Otherwise bar cells are green below -18 dB, yellow from -18 to -6 dB, red above -6 dB (colored by each cell's own level), CLIP in red.

## Pure renderer (testable)
`renderMeter(_ f: MeterFrame, width: Int, height: Int) -> [String]` returns the lines to draw (no cursor codes, no trailing newline). With `color == false` the lines contain no ESC characters. Every line's display width is at most `width`; there are at most `height` lines.

```swift
struct MeterFrame {
    var route: String        // "Quad Cortex mini → Audiofuse Studio"
    var detail: String       // "map 3-4:1-2   64 frames   gain 1.00"
    var outLabels: [String]  // ["OUT 1", "OUT 2"]
    var outDB: [Double]      // current level in dBFS, -60 or lower = silent
    var outHoldDB: [Double]
    var outClip: [Bool]
    var inLabels: [String]   // ["IN 3", "IN 4"]
    var inDB: [Double]
    var inHoldDB: [Double]
    var showInputs: Bool
    var state: String        // "connected"
    var events: [String]     // already formatted, e.g. "14:22:08 restored Audiofuse Studio"; last 3 shown
    var color: Bool
}
```
Layout, top to bottom (width W, label column 9 chars, readout column 21 chars, bar width B = W - 9 - 21 - 6 where the last 6 are the clip column ` CLIP ` or spaces):
1. ` patchthru   <route>    <detail>` (cut to W)
2. a rule of `─` x W
3. input rows if `showInputs` (one per input channel), then output rows. Row = ` <label padded to 7> ` (exactly 9 characters: space, 7-wide label, space) + bar + readout + clip column.
4. a scale row: labels `-60 -48 -36 -24 -12 -6 0` right-aligned under their tick positions (skip a label that would overlap the previous one)
5. a rule
6. ` <state>`
7. up to 3 event lines, each prefixed by two spaces
8. ` q quit   c clear clip   i inputs on/off`
Bar: `█` for filled cells, `░` for empty; filled = round((clamp(dB, -60, 0) + 60) / 60 * B). The hold marker `┃` replaces the cell at that hold level (if it is inside the bar and above the current level, or on it). Readout: dB with one decimal and ` dB` (`  -9.3 dB`), or ` -inf dB` at or below -60, then `  hold -6.1` (same rules) padded to the column width. If `W < 50` or `H < 10` return a single line `terminal too small (need 50x10)`. If there are fewer lines than needed (small H with many channels), drop in this order: help row, event lines (keep the newest), the scale row, then input rows.

## Testing aid
`thru meter-snapshot <width> <height> <outDB,outDB,...> [--inputs <inDB,...>] [--color]` prints one rendered frame for synthetic levels (holds equal the levels, no clip unless a level is >= 0). Labels `OUT 1..n` and `IN 1..n`, route `A → B`, detail `map test`, state `connected`, one event `12:00:00 test`. Exit 0. Not in the usage text.

## Colors (only when `color` is true; `NO_COLOR` turns them all off, and colors never change the layout)
- Header: `patchthru` bold cyan, the route bold, the config detail cyan.
- dB readouts and hold numbers take the color of their level, using the same thresholds as the bar cells: green below -18 dB, yellow from -18 to -6 dB, red above -6 dB. Silence (`-inf`) and the `dB` / `hold` words are faint.
- Rows: output labels bold, input labels faint. Rules and the scale row are faint. `CLIP` is bold white on red.
- State word: `connected` bold green, `muted` and `waiting` bold yellow, `rebuilding` bold magenta, `asleep` bold cyan.
- Events: the timestamp is faint; the message is red for loss and failures (`lost`, `could not`, `differ`), yellow for `waiting`, `rebuilding`, `sleeping`, green for `restored`, `unmuted`, `connected`, `woke`, `found`.
- Key legend: each key letter (`q`, `c`, `i`) is black on a cyan background, the rest of the legend is plain.

## RMS (peak + RMS bars)
- The audio callback keeps a running sum of squares per mapped channel (post-gain for outputs). The main queue turns that into a mean square per frame and smooths it with a 300 ms time constant; RMS dB = 10 log10(smoothed mean square), -120 when silent. A sine at peak P reads P - 3.01 dB.
- With RMS on (default in the live meter; `m` toggles), a row has three zones: `█` up to the RMS level, `▒` from there up to the peak level, `░` beyond; the hold tick `┃` is unchanged. The readout becomes ` <peak> dB  rms <rms>` in the same 21 columns (the hold number is dropped because the tick shows it). Level colors apply to both numbers.
- With RMS off, or when the frame carries no RMS data, rows are exactly the peak-only layout described above.
- Help row gains `m rms on/off` (cut to the terminal width like every other line).
- Testing aid: `thru meter-snapshot ... --rms <outDB,...>` supplies output RMS levels (this turns RMS rows on); `--in-rms <inDB,...>` does the same for input rows.
