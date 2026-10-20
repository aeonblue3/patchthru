# thru: resilience spec (watchdog, rebuild, sleep/wake, unmute holdoff)

Builds on docs/specs/cli-spec.md. New behavior and output lines (stdout, exact prefixes):

- `thru: rebuilding (<reason>)` then, once the devices are usable, the normal `thru: connected ...` line again. Reasons: `audio stalled` (audio callback count did not advance for 500 ms), `layout did not recover` (buffer layout or sub-device order wrong for 3 s while both devices are present), `debug` (testing hook below). While a device is simply absent thru does NOT rebuild (the aggregate rejoins it by itself).
- Sleep/wake: on system sleep thru tears down and prints `thru: sleeping`; on wake it prints `thru: woke` and then behaves as a fresh start (waiting/found/connected lines as devices reappear).
- Unmute holdoff: after ANY connect other than the very first of the process, and after any device loss, output stays muted until the layout and sub-device order have been valid for 2 s, then fades in over ~50 ms and thru prints `thru: unmuted`. The very first connect is not held (no `unmuted` line).
- Rebuild failures after the first successful connect never exit the process; they retry every 500 ms. Before the first connect, three failures still exit 4.
- Testing hook (not in usage text): env `THRU_DEBUG_REBUILD_AFTER=<seconds>` forces one rebuild with reason `debug` that many seconds after the first connect.

Additions after review:
- After the first connect nothing exits the process: ambiguous matches, missing devices (even with `--no-wait`), rate mismatches and map failures all retry. Retry notices: `thru: could not connect: <reason>; retrying` (stdout, printed once per distinct reason).
- A rebuild reuses the channel map chosen at the first connect and never rewrites the saved route.
- Repeated "layout did not recover" rebuilds back off (3 s, 6 s, 12 s, 24 s, 48 s).
- The watchdog ignores stalls while a device is absent and for 2 s after connect. A fault shorter than a supervisor tick still restarts the 2 s holdoff.
- If the wake notification is missed, a wall-clock-versus-uptime gap of more than 2 s ends the sleeping state.
