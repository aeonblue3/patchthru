# thru: device aliases spec

An alias is a short name you choose for a device specifier, optionally with the channels to use on that device. Stored in `~/.config/thru/aliases.json` (`HOME` env respected): `{"qc": {"device": "Quad Cortex mini", "channels": "3-4"}}`. Alias names are stored lowercase and matched case-insensitively.

## Commands
```
thru alias                          list aliases (same as `thru alias list`); `--json` for machine output
thru alias add <name> <device> [--channels SIDE]    create or replace
thru alias rm <name>                delete
```
- `<device>` is any specifier thru already accepts: part of the device name (case-insensitive) or an exact UID. Saved as typed; not checked against attached hardware, but if nothing matches right now, print `thru: note: no device currently matches '<device>'` to stderr (still saved, exit 0).
- `SIDE` is one side of a map: `3-4`, `1`, `1,3`, `1-2,5`. Validated with the same rules as the map parser (1-based, ranges not reversed, no empty lists); bad value: exit 3, stderr `thru: bad channels: <reason>`.
- `<name>`: letters, digits, `.`, `_`, `-`; must not start with `-`; must not be a command word (`list`, `inspect`, `map-check`, `alias`, `help`, `version`). Violations: exit 1 with `thru: bad alias name: <reason>` on stderr.
- `rm` of an unknown alias: exit 2, `thru: no alias '<name>'`.

## Output lines (stdout)
- add: `thru: alias <name> -> <device>` plus ` (channels <SIDE>)` when set; `thru: alias <name> updated -> ...` when replacing.
- rm: `thru: alias <name> removed`.
- list: one line per alias, sorted by name: `<name> -> <device> (channels <SIDE>) [<state>]` where `(channels ...)` is omitted when unset and `<state>` is `connected: <actual device name>`, `not connected`, or `ambiguous` for the current device list. `thru alias` with none defined prints `thru: no aliases` (exit 0). `--json`: array of `{name, device, channels, state}`.

## Using aliases in a route
`thru <in> <out>`: each of `<in>` and `<out>` is looked up as an alias first; if it is one, its `device` replaces the text before device matching. Aliases win over a device whose name happens to contain the same text. Output lines still print the real device names. The text as typed (the alias) is what gets saved in last.json and used for the `waiting for '<text>'` line.

Channel precedence for the map: `--map` > alias channels > the built-in default (driver channel named "wet", else first stereo pair).
- Both aliases have channels: map is `<inSide>:<outSide>` (e.g. `thru qc af` with qc=3-4, af=1-2 gives `3-4:1-2`).
- Only the input alias has channels: output side is `1-N`, N = number of input channels chosen. Only the output alias has channels: input side is `1-N`, N = number of output channels chosen.
- Neither: unchanged default.
An alias's `channels` is a side of the map for that direction only; the same alias used as `<in>` supplies the input side and used as `<out>` the output side.
