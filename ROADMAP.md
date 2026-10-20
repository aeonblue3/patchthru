# Roadmap

Known gaps, roughly in order of how likely they are to matter to you.

- Devices with more than one audio stream (some pro interfaces) are rejected with an error. Supporting them means mapping channels across buffers.
- Input and output on the same device (e.g. monitoring one interface through itself) is not supported; it needs a single-device path without an aggregate.
- Listen for device-list and alive notifications instead of polling (the device list is checked every 200 ms).
- Re-check sample rates after a replug; handle another app taking exclusive access.
- Print `stopped` and tear down cleanly on SIGHUP and SIGPIPE.
- Measure the end-to-end latency of the passthrough itself, not just the device pair.
- A Homebrew tap that builds from source; signed and notarized release binaries.
