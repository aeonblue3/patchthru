# thru: command-line spec

`thru` routes one macOS audio input device to one output device with minimal latency. Foreground process, Swift, no dependencies, CoreAudio and IOKit (power events) only. Built as a SwiftPM executable named `thru` (Sources/thru). Binary after `swift build -c release`: `.build/release/thru`.

## Commands
```
thru <in> <out> [--map SPEC] [--buffer N] [--gain G] [--no-wait] [--meter]   route until Ctrl-C
thru                                                                          rerun the last route (saved file)
thru list [--json]                                                            devices with channel counts
thru inspect <device>                                                         aggregate composition as JSON (read-only)
thru map-check <SPEC> <inChannels> <outChannels>                              print resolved pairs as JSON (testing aid)
```
- `<in>` / `<out>`: case-insensitive substring of the device name, or the exact UID. `<in>` must have input channels, `<out>` output channels. More than one match: exit 2 and list candidates. No match: wait and print `thru: waiting for '<text>'` unless `--no-wait` (then exit 2).
- `--buffer N` frames, default 64, clamp to 32...512. `--gain G` 0...1, default 1. `--meter` prints in/out peaks once per second.
- The last successful route is saved to `~/.config/thru/last.json` (inputText, outputText, map, buffer, gain). `thru` with no args loads it; if absent, print usage, exit 1.

## Channel map SPEC
`A:B` where A is the input side and B the output side. Each side is a comma list of 1-based channels or ranges: `3-4`, `1,3`, `1-2,5`. Examples: `3-4:1-2`, `1:1-2`, `1-2:7,8`.
- Equal counts pair elementwise (3->1, 4->2). One input channel with N outputs fans out. Anything else is an error.
- Channel numbers must be >= 1 and <= the device's channel count. An output channel may appear only once (no summing). Input channels may repeat.
- Default (no `--map`): if the input device has a channel whose driver name contains "wet", that channel and the next one (e.g. `3-4:1-2`); otherwise when both devices have >= 2 channels: `1-2:1-2`. If the input has 1 channel: `1:1-2` (fan-out). If output has 1 channel: `1:1`.
- Errors: exit code 3, message to stderr starting `thru: bad map:`.

## Exit codes
0 clean exit (signal) / success; 1 usage; 2 device not found (only with --no-wait) or ambiguous; 3 bad map; 4 CoreAudio failure, or devices that cannot be routed (e.g. different sample rates).

## Output contract (stdout, one event per line, exact prefixes; tests depend on these)
- `thru: waiting for '<text>'` (once per missing device, then `thru: found '<name>'` when it appears)
- `thru: connected <inName> -> <outName> map=<spec> buffer=<N> first-audio=<ms>ms`
- `thru: lost <deviceName>` / `thru: restored <deviceName>` when a routed device disappears / returns (aggregate heals itself; thru mutes while the buffer layout is wrong and fades in over ~50 ms when it is right again)
- `thru: meter in=<peak> out=<peak>` every second with --meter
- `thru: stopped` on SIGINT/SIGTERM after tearing down, exit 0

## Engine facts (measured on the author's rig, 2026-10; see docs/DESIGN.md)
- One PRIVATE aggregate: sub-devices [input device (drift compensation ON), output device (drift OFF, main/clock)]. Keys: name "name", uid "uid", private "private"=1, stacked "stacked"=0, main "master"=<output UID>, subdevices "subdevices", per-sub-device "uid" and "drift". Aggregate buffer size set with kAudioDevicePropertyBufferFrameSize drives both devices' cycles.
- Create ~18 ms, start->first callback ~65 ms. Aggregate buffer order follows sub-device order: input buffer 0 = input device, output buffer 1 = output device (locate by channel count, not index, and re-validate every cycle).
- When a sub-device vanishes the IOProc KEEPS FIRING with fewer buffers or zero-channel buffers. The callback must, every cycle, validate buffer count, mNumberChannels, mData != nil, byte size; on any mismatch zero the output and return. Never index without checking. No allocation, no locks, no Swift arrays/closures that allocate, no logging inside the callback.
- The aggregate rejoins a replugged sub-device by itself. UID is stable across replug; AudioObjectID changes. Match by UID.
- A private aggregate disappears with its process (kill -9 leaves nothing).
- Quad Cortex mini: processed guitar is USB input channels 3-4 ("Wet Signal L/R"); 1-2 are DRY inputs. Audiofuse Studio: outputs 1-2 are MAIN L/R.
- Never create, change or destroy any non-private aggregate (a user-made aggregate, e.g. from Audio MIDI Setup, must stay untouched).
- Device changes are detected by polling the device list every 200 ms (listeners are on the roadmap). Run the poll on the main queue, never on the audio thread.
