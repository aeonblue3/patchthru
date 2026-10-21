# patchthru

`thru` routes any audio input device on your Mac to any output device, from the command line, with no DAW open. Plug in a guitar modeler, run one command, and hear it through your monitor interface.

```
thru "quad cortex" audiofuse
```

It builds one small CoreAudio route, keeps it alive across unplugs, sleep and wake, and takes itself apart when you press Ctrl-C. It never changes your system's default devices or leaves any setting changed on your hardware.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [Bun](https://bun.sh), only if you want to run the tests
- Developed and tested on Apple silicon with macOS 26. Intel Macs should build but have not been tried.

## Install

```
git clone https://github.com/aeonblue3/patchthru.git
cd patchthru
swift build -c release
mkdir -p ~/.local/bin && ln -sf "$PWD/.build/release/thru" ~/.local/bin/thru
thru --version
```

If `thru` isn't found, add `~/.local/bin` to your PATH (`export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`), or link into any directory that's already on it.

To uninstall, delete the symlink and the cloned folder. `thru` writes only to `~/.config/thru/`.

## Quick start

```
thru list                              # see your devices and their channel counts
thru "quad cortex" audiofuse --gain 0.3    # route; Ctrl-C to stop
thru                                   # run the last route again
```

A device is any part of its name (case-insensitive) or its exact UID. If a name matches several devices, `thru` lists them and stops instead of guessing (an exact name match wins over a partial one). If a device isn't plugged in yet, `thru` waits for it (use `--no-wait` to exit instead).

Start with a low `--gain`. Output goes straight to the output device you chose.

Options: `--gain 0..1` (default 1), `--buffer 32..512` frames (default 64, smaller is lower latency and uses more CPU), `--meter` (the full-screen meter, below), `--map` (below).

## Meter

`thru qc af --meter` takes over the terminal with a live meter for each mapped output channel: a bar from -60 to 0 dBFS, a peak-hold tick, a latching CLIP marker, and the level as a number. The bar is solid up to the RMS level and shaded up to the peak, so you can see average loudness and peaks together (RMS uses a 300 ms window).

Keys: `q` quit, `c` clear clip markers, `i` show the input channels above the outputs, `m` turn RMS on or off. Events (lost, restored, unmuted, ...) appear in a small log under the bars instead of scrolling. Your scrollback comes back when you exit. Set `NO_COLOR=1` for no colors. If stdout isn't a terminal, `--meter` prints one `thru: meter in=... out=...` line a second instead.

## Choosing channels

`--map IN:OUT` lists input channels on the left and output channels on the right, 1-based, with commas and ranges:

```
thru in out --map 3-4:1-2     # inputs 3 and 4 to outputs 1 and 2
thru in out --map 1:1-2       # one input to both outputs
thru in out --map 1-2:7,8     # a stereo pair to outputs 7 and 8
```

Equal counts pair up in order; one input channel can fan out to several outputs. An output channel can be used once. With no `--map`, `thru` uses the input's "Wet" channel pair if the driver names one (a Quad Cortex does), otherwise the first stereo pair.

## Aliases

Give devices names you like, optionally with the channels to use:

```
thru alias add qc "Quad Cortex" --channels 3-4
thru alias add af Audiofuse --channels 1-2
thru qc af                             # same as --map 3-4:1-2
thru alias                             # list them and see which are connected
thru alias rm qc
```

Aliases live in `~/.config/thru/aliases.json`. Channel precedence is `--map`, then alias channels, then the default above.

## Reliability

- Unplug or power off either device and `thru` mutes and keeps running. When the device returns the route comes back by itself (`restored`) and fades in after about 2 seconds of steady audio (`unmuted`).
- Putting the Mac to sleep tears the route down and rebuilds it on wake.
- If the audio callback stops, or the layout stays wrong for 3 seconds with both devices present, `thru` rebuilds the route.
- Events print to the terminal: `connected`, `lost`, `restored`, `unmuted`, `rebuilding`, `sleeping`, `woke`.

## Safety

- Don't send an output back into the input you are playing; that makes a feedback loop.
- macOS may ask your terminal app for microphone access the first time, because reading an audio input counts.
- `thru` won't change a device's sample rate. If the two devices run at different rates it says so and waits; set them to match in Audio MIDI Setup.

## Known limitations

- Devices with more than one audio stream are rejected for now.
- Input and output on the same device are not supported yet.
- macOS only.

See [ROADMAP.md](ROADMAP.md) for what's planned and [docs/DESIGN.md](docs/DESIGN.md) for how it works and what was measured.

## Latency

On the author's rig (a USB modeler into a USB audio interface, 48 kHz) the worst case through the pair is about 8.8 ms at 64 frames, 11.5 ms at 128 and 27.5 ms at 512. Yours will differ with hardware. Details in the design notes.

## Tests

Build first (`swift build -c release`), then:

```
bun test tests/
```

This runs the black-box tests that need no hardware (set `THRU_BIN` to test a different binary). Tests that need real devices only run with `THRU_HW=1`; `THRU_IN` and `THRU_OUT` pick the device names (default "quad cortex" and "audiofuse"), and they are written around the author's Quad Cortex mini and Audiofuse Studio. Expect some to fail on other gear. The tests use a temporary home directory, so they never touch your saved route or aliases.

## Command reference

```
Usage:
  thru <in> <out> [--map SPEC] [--buffer N] [--gain G] [--no-wait] [--meter]   route until Ctrl-C
  thru                                                                          rerun the last route (saved file)
  thru list [--json]                                                            devices with channel counts
  thru inspect <device>                                                         aggregate composition as JSON (read-only)
  thru map-check <SPEC> <inChannels> <outChannels>                              print resolved pairs as JSON (testing aid)
  thru alias [list] [--json]                                                    list your device aliases
  thru alias add <name> <device> [--channels SIDE]                              create or replace an alias
  thru alias rm <name>                                                          delete an alias
  thru --version                                                                print the version

Options:
  --buffer N  frames, default 64, clamped to 32...512
  --gain G    0...1, default 1
  --meter     full-screen peak and RMS meter (q quit, c clear clip, i inputs, m RMS); plain lines when not a terminal
  --no-wait   exit 2 immediately if device not found

Channel Map SPEC:
  Format: A:B where A and B are comma-separated 1-based channels or ranges.
  Examples: 3-4:1-2, 1:1-2, 1-2:7,8
  Default: the input's "Wet" channel pair if the driver names one, else 1-2:1-2 (>=2 channels), 1:1-2 (1 input), 1:1 (1 output)
  Example: thru "quad cortex" audiofuse --map 3-4:1-2

Aliases:
  A device is any part of its name (see 'thru list') or its exact UID. To name a device yourself:
    thru alias add qc "Quad Cortex" --channels 3-4
    thru alias add af "Audiofuse" --channels 1-2
    thru qc af                       -> map 3-4:1-2
  Precedence for channels: --map, then alias channels, then the default.

Exit Codes:
  0  clean exit (signal) / success
  1  usage error
  2  device not found (with --no-wait) or ambiguous match
  3  bad map specification
  4  CoreAudio failure, or devices that cannot be routed (e.g. different sample rates)

Saved Route:
  Last successful route saved to ~/.config/thru/last.json.
  Running 'thru' with no arguments loads and reruns it.
  If no saved route exists, prints this usage and exits 1.
```

## License

MIT. See [LICENSE](LICENSE).
