# Security

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private vulnerability reporting (the repository's **Security** tab, **Report a vulnerability**) once the repository is published. Include the version or commit, what an attacker needs, and a reproduction.

Until 1.0 only the latest release and `main` receive fixes.

## Threat model

`blueherald` gives an AI agent control over Bluetooth hardware. Two things can go wrong: the agent does something to a device that it should not, or a device does something to the agent.

### The agent writing to hardware

- **Read-only by default.** `ble_write`, `ble_write_descriptor` and `ble_transact` are not even listed until `BLUEHERALD_ALLOW_WRITES` is set.
- **Narrow what may be written.** `BLUEHERALD_WRITE_ALLOWLIST` limits writes to characteristics, `BLUEHERALD_WRITE_VALUE_ALLOWLIST` (or its file) to exact frames, and `BLUEHERALD_WRITE_DENYLIST` removes characteristics whatever else is configured. Descriptor writes are checked against their characteristic. For a device whose commands share one characteristic, list frames, not the characteristic.
- **Writes can damage hardware** (firmware update characteristics, calibration, motor and lock controls). Allow exactly the frames you have reviewed.
- Limits on connections, subscriptions, scans and buffers (`BLUEHERALD_MAX_*`) bound what a runaway agent can hold open.

### A device steering the agent

Advertised names, 0x2901 descriptions and the text of values are chosen by whoever built the device, and they reach the agent's context. A device can name itself with an instruction. The server limits what a name can carry (control and invisible formatting characters removed, text cut to 64 characters for names and descriptions, 128 for value text; `hex` always has the whole value) and tells the agent to treat all of it as data. Cleaning cannot tell intent, so keep writes off, or narrowed to exact frames, when you work with devices you do not control. A capture file loaded with `BLUEHERALD_REPLAY` is device data too, and so is one you did not record.

### Other surfaces

- **No network listener.** The server speaks MCP over stdio only. It never loads plugins or runs code supplied by an agent or a device.
- **Captures hold what crossed the air**: written values, notifications, reads and the advertised names of the device under test, with CoreBluetooth peripheral identifiers (per Mac). Treat a capture as sensitive when the device carries personal data, and review it before sharing it.
- **Bluetooth permission.** To get its own macOS permission, `blueherald` relaunches itself once at startup as its own responsible process (`BLUEHERALD_OWN_PERMISSION=0` disables it). The relaunch executes the same binary with the same arguments and environment.
- Development builds are ad-hoc signed, so each rebuild is a new identity to macOS.
