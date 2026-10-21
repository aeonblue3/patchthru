

let usageText = """
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
"""
