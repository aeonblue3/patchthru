# Design notes

Everything below was measured on the author's rig (Quad Cortex mini into an Audiofuse Studio, Apple silicon, macOS 26) unless marked otherwise. Other hardware will differ.

## Approach

`thru` builds one private CoreAudio aggregate device containing the input device (drift compensation on) and the output device (the clock), sets the aggregate's buffer size, and runs a single native audio callback that copies the chosen input channels to the chosen output channels. CoreAudio does the clock-drift correction between the two USB clocks. A private aggregate is invisible to other processes and disappears when `thru` exits, even on `kill -9`, so it leaves nothing behind and never changes a device's settings for good or the system default devices (it sets the buffer size of its own private aggregate while it runs).

The audio callback is a C-convention function with no Swift runtime calls, no allocation and no locks. A vanished sub-device does not stop the callback: it keeps firing with fewer or empty buffers. So the callback validates the whole buffer layout on every cycle and outputs silence on any mismatch.

## Timing

- Aggregate creation about 18 ms. Launch to first audio callback about 50 to 110 ms.
- Click-to-click latency through the device pair follows `2 x buffer + 296` frames at 48 kHz, exact at every buffer size tested (the 296 is the fixed hardware cost). The worst case, a signal arriving at the start of a cycle, is that number; the average is about half a buffer lower.

| buffer (frames) | worst case |
|---|---|
| 512 | 27.5 ms |
| 256 | 16.8 ms |
| 128 | 11.5 ms |
| 64 (default) | 8.8 ms |
| 32 | 7.5 ms |

No dropped cycles over 20 s at 128, 64 or 32 frames with silent audio. Measured with a click on one output, a cable into the modeler's input, and timestamps on the USB return. The latency of `thru`'s own passthrough was not measured separately; it uses the same aggregate design.

## Device loss and return

- A sub-device unplug leaves the aggregate alive and the callback running with a shorter buffer list, plus a one-off timing jump (about 120 ms for the modeler, about 600 ms when the clock device goes).
- On replug the aggregate takes the device back by itself with its original layout. UIDs are stable; the numeric device ID changes every time, so devices are matched by UID.
- The modeler's audio is back within about 0.7 s of the replug event. The clock device's layout is valid within about 0.5 s but audio returns 1.5 to 2.5 s later, so after any loss the output stays muted until the layout has been right for 2 s, then fades in over about 50 ms.
- The supervisor rebuilds the aggregate only if the callback stops for 500 ms, or if the layout stays wrong for 3 s with both devices present. A device that is merely absent never causes a rebuild.
- System sleep: `thru` tears down on the will-sleep notification and rebuilds on wake. A wall-clock check covers a missed wake notification.

## Quirks worth knowing

- A Quad Cortex mini exposes its processed signal on USB inputs 3-4 ("Wet Signal L/R"); inputs 1-2 are the dry inputs. With no `--map`, `thru` prefers an input pair whose driver channel name contains "wet".
- An audio interface's Aux/Cue outputs may follow its internal mixer instead of USB playback; check the interface's control panel if a USB channel seems silent.
- Several audio APIs reported different buffer sizes for the sub-devices (512) and the aggregate (the value you set); the aggregate's setting is what drives latency.

## Not verified

Other hardware, Intel Macs (the code compiles for x86_64 but has not been run there), USB-port changes, another app taking exclusive access, and long sessions.
