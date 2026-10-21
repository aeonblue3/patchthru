# patchthru

`thru` sends the sound from one audio device on your Mac to another, straight from the command line. You don't need a DAW or any other audio app open.

For example, to hear a guitar modeler through the speakers or headphones plugged into your audio interface:

```
thru "quad cortex" audiofuse
```

That's the whole command: the device you're listening *from*, then the device you're listening *through*. `thru` keeps running until you press Ctrl-C, and the sound keeps flowing the whole time.

While it runs, `thru` handles the annoying parts for you. If you unplug a device or your Mac goes to sleep, it picks back up on its own when the device returns. When you stop it, it cleans up after itself. It never changes your Mac's default sound devices or any settings on your hardware.

## Requirements

- macOS 13 or later.

- Xcode Command Line Tools. Install them with `xcode-select --install`.

- [Bun](https://bun.sh), but only if you want to run the tests.

`thru` was built and tested on an Apple silicon Mac running macOS 26. It should also build on Intel Macs, but nobody has tried that yet.

## Install

```
git clone https://github.com/aeonblue3/patchthru.git
cd patchthru
swift build -c release
mkdir -p ~/.local/bin && ln -sf "$PWD/.build/release/thru" ~/.local/bin/thru
thru --version
```

If the last line says `command not found`, your shell doesn't know to look in `~/.local/bin` yet. Add this line to your `~/.zshrc`, then open a new terminal window:

```
export PATH="$HOME/.local/bin:$PATH"
```

**To uninstall,** delete the `~/.local/bin/thru` link and the cloned `patchthru` folder. The only other place `thru` saves anything is `~/.config/thru/`, so delete that too if you want a clean slate.

## Getting started

### 1. See what devices you have

```
thru list
```

This prints every audio device your Mac can see. Each line shows the device's name, how many input and output channels it has, its sample rate, and its UID (a unique ID that macOS assigns to it). The output looks something like this, with your own devices in place of these:

```
MacBook Pro Microphone  in 1   out 0    48000 Hz  BuiltInMicrophoneDevice
MacBook Pro Speakers    in 0   out 2    48000 Hz  BuiltInSpeakerDevice
Quad Cortex mini        in 8   out 8    48000 Hz  ...
Audiofuse Studio        in 18  out 18   48000 Hz  ...
```

A device with `in 0` has nothing to send, so it can only be used as an output. A device with `out 0` can only be used as an input.

### 2. Start a route

Give `thru` the input device first and the output device second:

```
thru "quad cortex" audiofuse --gain 0.3
```

**Turn your speakers or headphones down before you run this the first time.** The sound goes straight to the output at full volume unless you lower it. The `--gain` option sets the volume from `0` (silent) to `1` (full, the default), so `--gain 0.3` is a safe place to start.

### 3. Stop it

Press **Ctrl-C**. `thru` removes everything it set up and exits.

### 4. Run it again later

```
thru
```

With nothing after it, `thru` repeats the last route that worked, with the same options.

## Naming devices

You don't have to type a device's full name. Any part of the name works, and capital letters don't matter. For example, if your device is called `Quad Cortex mini`, all of these find it:

```
thru "quad cortex" audiofuse
thru cortex audiofuse
thru QUAD audiofuse
```

If the part you type contains a space, put it in quotes, as in `"quad cortex"`. Without quotes, the shell would treat `quad` and `cortex` as two separate devices.

**How `thru` decides which device you meant.** It tries these in order and stops at the first one that matches:

1. **An alias you created.** See [Aliases](#aliases) below.

2. **The device's exact UID.** This is the last column in `thru list`. Unlike names, a UID must be typed exactly, capital letters included.

3. **The device's exact full name**, ignoring capital letters.

4. **Any part of the device's name**, ignoring capital letters.

**It only looks at devices that make sense for that spot.** For the input, it ignores devices that have no input channels. For the output, it ignores devices with no output channels. So with the devices listed above, `macbook` as an input means the microphone, and `macbook` as an output means the speakers. Neither one is ambiguous, even though both names contain "macbook."

**When a name matches more than one device,** `thru` won't guess. It prints all the devices that matched and stops, so you can type a longer piece of the name, or use the UID. If one device's full name is exactly what you typed, that device wins over the others, which only match part of their name.

**When nothing matches,** `thru` assumes the device isn't plugged in yet and waits for it. As soon as you plug it in, the route starts. If you'd rather it give up right away, add `--no-wait`.

Devices you've combined in Audio MIDI Setup (aggregate devices) can't be used with `thru`.

## Options

| Option | What it does |
|--------|--------------|
| `--gain G` | Volume from `0` (silent) to `1` (full). Default is `1`. |
| `--buffer N` | Audio buffer size in frames, from `32` to `512`. Default is `64`. Smaller numbers mean less delay but more work for your CPU. Raise it if you hear clicks or dropouts. |
| `--map IN:OUT` | Choose which channels go where. See [Choosing channels](#choosing-channels). |
| `--meter` | Show live level meters while the route runs. See [Meter](#meter). |
| `--no-wait` | If a device isn't plugged in, exit right away instead of waiting for it. |

## Choosing channels

Audio interfaces often have many channels. By default, `thru` picks a sensible stereo pair:

- If the input device labels a pair of channels "Wet" (a Quad Cortex does this for its processed signal), it uses those.

- Otherwise, it uses the input's first two channels.

Either way, they go to the output's first two channels.

To pick channels yourself, use `--map`. Input channels go on the left of the colon and output channels on the right. Channels are numbered starting at 1, and you can list them with commas or give a range with a dash:

```
thru in out --map 3-4:1-2     # input channels 3 and 4 go to output channels 1 and 2
thru in out --map 1:1-2       # input channel 1 goes to both output channels 1 and 2
thru in out --map 1-2:7,8     # input channels 1 and 2 go to output channels 7 and 8
```

When both sides list the same number of channels, they pair up in order: first with first, second with second. One input channel can feed several outputs, like the mono-to-both-sides example above. Each output channel can only be used once.

## Aliases

If you route the same devices often, give them short names. An alias can also remember which channels to use:

```
thru alias add qc "Quad Cortex" --channels 3-4
thru alias add af Audiofuse --channels 1-2
```

Now this:

```
thru qc af
```

does the same as `thru "Quad Cortex" Audiofuse --map 3-4:1-2`.

The device part of an alias (`"Quad Cortex"` above) follows the same [naming rules](#naming-devices) as everywhere else, so part of the name is fine.

To manage your aliases:

```
thru alias            # list your aliases and show which devices are plugged in
thru alias rm qc      # delete one
```

Aliases are saved in `~/.config/thru/aliases.json`.

If channels are set in more than one place, `--map` wins. Next come the alias's channels, and if neither is set, the default pair described above.

## Meter

Add `--meter` to see how loud the signal is while it runs:

```
thru qc af --meter
```

This takes over your terminal window and shows one bar per output channel, from -60 dB (very quiet) to 0 dB (the loudest possible before distortion). Each bar shows:

- **The average level**, as the solid part of the bar (averaged over the last 0.3 seconds).

- **The peaks**, as the lighter shaded part past it.

- **A peak marker** that holds the highest recent level for a moment.

- **A CLIP warning** that stays lit once the signal hits the top, so you don't miss a brief overload.

- **The level as a number.**

Messages like "lost" or "restored" appear in a small log under the bars.

**Keys:**

| Key | What it does |
|-----|--------------|
| `q` | Quit |
| `c` | Clear the CLIP warnings |
| `i` | Also show the input channels above the outputs |
| `m` | Turn the average-level display on or off |

When you quit, your terminal goes back to how it was. Set `NO_COLOR=1` if you don't want colors. If `thru`'s output is going to a file or another program instead of a terminal window, `--meter` prints one line of levels per second instead.

## What happens when things change

`thru` is built to keep running unattended. It prints a short message each time something happens:

| Message | What it means |
|---------|---------------|
| `connected` | The route is up and audio is flowing. |
| `waiting for '...'` | A device isn't plugged in yet. `thru` will start as soon as it shows up. |
| `lost` | A device was unplugged or turned off. `thru` goes silent and keeps running. |
| `restored` | The device is back and the route is rebuilt. |
| `unmuted` | After about 2 seconds of steady audio, the sound fades back in. |
| `sleeping` / `woke` | Your Mac went to sleep, then woke up. `thru` takes the route down on sleep and rebuilds it on wake. |
| `rebuilding` | Something went wrong behind the scenes, so `thru` is starting the route over. This happens if the audio stops unexpectedly, or if the route stays set up wrong for 3 seconds while both devices are plugged in. |

## Things to know

- **Watch out for feedback.** If the output you choose can play back into the input you're using, you'll get a loud, growing squeal. Make sure the sound from the output can't reach the input.

- **macOS may ask for microphone permission.** The first time you run `thru`, your terminal app may ask to use the microphone. macOS asks this whenever an app listens to *any* audio input, not just a microphone, and `thru` has to listen to your input device to send its sound anywhere. Click Allow. If you click Don't Allow by mistake, you can turn it back on in System Settings → Privacy & Security → Microphone.

- **Both devices must use the same sample rate.** If they don't, `thru` tells you and waits instead of changing anything. Open Audio MIDI Setup (in Applications → Utilities), set both devices to the same rate, such as 48,000 Hz, and the route will start.

## Known limitations

- Some devices present their audio as more than one stream. `thru` can't route those yet.

- The input and the output must be two different devices for now.

- `thru` only runs on macOS.

See [ROADMAP.md](ROADMAP.md) for what's planned, and [docs/DESIGN.md](docs/DESIGN.md) for how it works under the hood.

## Latency

Latency is the delay between playing a note and hearing it. On the author's setup, a guitar modeler connected by USB going into a USB audio interface at 48,000 Hz, the longest delay measured was about:

| `--buffer` | Delay |
|------------|-------|
| 64 (default) | 8.8 ms |
| 128 | 11.5 ms |
| 512 | 27.5 ms |

Your numbers will depend on your hardware. The design notes have the details.

## Running the tests

Build first, then run the tests with Bun:

```
swift build -c release
bun test tests/
```

These tests don't need any audio hardware. To test a different copy of `thru`, set `THRU_BIN` to its path.

Some tests need real devices plugged in, and they only run when you set `THRU_HW=1`. Use `THRU_IN` and `THRU_OUT` to name your input and output devices (they default to `"quad cortex"` and `"audiofuse"`). These tests were written around the author's Quad Cortex mini and Audiofuse Studio, so expect some to fail on other gear.

The tests use a temporary home folder, so they never touch your saved route or aliases.

## Command reference

This is the same text `thru` prints when you run it with no saved route.

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
