---
name: hardware-verify
description: Check a BlueHerald change against a real Bluetooth peripheral with a release build, because the unit tests run against FakeCentral and cannot see CoreBluetoothCentral. Use after any change to BlueHeraldCoreBluetooth, to actor, continuation or cancellation code anywhere, to the stdio transport or shutdown, and before a release.
---

# Hardware verify

`CoreBluetoothCentral` is the one layer the tests cannot reach, and the optimiser has changed how its
actor hops behave before: debug builds passed while the release build crashed. So the check is always
a **release** build against a real peripheral, with `Scripts/hardware-smoke.swift`.

## What you need

- A connectable peripheral in range. A phone running a BLE tester app that offers a virtual device
  (LightBlue, nRF Connect) works; it often advertises under a different name than it connects as, and
  may only advertise while the app is in the foreground and the phone is unlocked.
- Bluetooth permission for the rebuilt binary. Every rebuild is a new identity to macOS, so the first
  start prompts again, which only a person can accept. While it is pending `ble_status` reports
  `awaiting_permission`.
- Nothing else holding the peripheral's single connection.

## Run

```bash
swift build -c release
swift Scripts/hardware-smoke.swift --name "<advertised name>" --read 2A29,2A19 [--subscribe 2A2B]
```

It scans, connects, reads, subscribes, disconnects, stops the server with SIGTERM while connected and
checks the capture it wrote, read-only, and exits non-zero on any failure. `--peripheral <id>` connects
to an id this Mac already knows.

To exercise a request/reply exchange, add `--transact CHAR:HEX:REPLY[:PREFIX]`. That is the only write
the script makes, and the server it starts allows exactly that frame. Choose a frame you know is
harmless for the device (an authentication hello, a read-style command), never one you have not read the
protocol for.

To check replay, record one run with `BLUEHERALD_CAPTURE`, then run the script again against
`BLUEHERALD_REPLAY` of that file and `blueherald diff` the two captures: they should be identical.

## Reading a failure

- **"Scan finds the peripheral" fails:** the peripheral is not advertising (app in the background,
  phone locked, device idle), or it advertises under another name. Not a BlueHerald bug until you have
  confirmed it with another scanner.
- **Timeout on first call after a rebuild:** the permission prompt is waiting.
- **A step fails only in release:** treat it as a real finding. Look first at actor hops and
  continuations (`ble-semantics-review` section 3).
- **Everything passes but the capture differs on replay:** the capture format or the replay matching
  changed (`ble-semantics-review` section 6).

## Rules

- Never write to a characteristic you do not own. Restrict writes with
  `BLUEHERALD_WRITE_VALUE_ALLOWLIST` to exact frames, and keep `BLUEHERALD_ALLOW_WRITES` off otherwise.
- Do not install the build over the copy another session or project uses without a temporary name and
  a `mv`; that session may be running it.

## Reporting

Say which build (`-c release`), which peripheral, how many checks passed of how many, and what could
not be checked (no notifying characteristic, no replying peripheral). "Tests pass" is not a hardware
result.
