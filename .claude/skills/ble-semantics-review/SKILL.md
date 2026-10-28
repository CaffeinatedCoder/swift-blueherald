---
name: ble-semantics-review
description: Review a change for answers that look right but are wrong — a reply paired with the wrong request or device, a write that sends bytes nobody wrote, a capture that replays against the wrong peripheral. Use when changing BLESession, CoreBluetoothCentral, PendingOperations, hex and value parsing, the write policy, capture or replay code, the stdio transport, or a tool's result, and before cutting a release.
---

# BLE semantics review

The dangerous failure here is not a crash. It is an answer that looks right: a read that returns the
previous read's value, a notification taken for the reply to a write it preceded, `"1:2:3:4"` decoded
to `12 34` and written to a device, a capture whose second device replays as the first. Nothing
throws, the agent gets a confident result, and the hardware or the next decision builds on it.

Generic code review does not look for this. This skill is that lens, built from the defects the bug
sweeps actually found.

## How to use this

Work through the sections that touch the change. Answer each question against the code, not the docs,
which may describe the intent. When a question has no obvious answer, **write the test that answers
it**: that is usually faster than reasoning, and it is what found every confirmed defect. Report a
finding with the concrete scenario: what the agent asked, what the server answered, what was
correct.

## 1. Every answer belongs to exactly one request

CoreBluetooth cannot withdraw a request it has sent, and reports a read response and a notification
through the same callback.

- A request that times out or is cancelled must leave a placeholder in its FIFO queue, so the late
  callback is used up on it and does not answer the next request of that kind
  (`PendingOperations`). Does every new request kind do the same? Does a disconnect clear the
  placeholders with the rest?
- A notification that arrives while a read of the same characteristic is pending is taken as the read
  result; is a late read reply ever emitted as a notification?
- `transact` takes its reply from notifications after a session-wide sequence mark taken just before
  the write. Is the mark taken before the write goes out, and the subscription active before it? A
  joiner of a subscription still being enabled must wait until it is active, and retry if it was
  discarded.
- When several devices are connected, can another device's notification become this device's reply?

## 2. Identity: peripheral, service, characteristic

- A characteristic UUID can appear in two services of one device, and two connected devices can expose
  the same table. Does every row, lookup and match carry the peripheral and the service, or does it
  key on the UUID alone (`ambiguous_characteristic` exists for this)?
- Peripheral ids are per Mac. Does anything compare them across captures or hosts (`ble-mcp diff`
  must not)?
- An attempt, a subscription or a scan that outlives its owner: does it remove or claim only its own
  entry (connect attempts carry an attempt number for this reason)?

## 3. Actors are re-entrant, and so are continuations

- Every method of `BLESession` that suspends must re-validate its preconditions afterwards and claim
  capacity *before* awaiting. After a `await`, is the connection, scan or subscription still the one
  you checked?
- A callback, a timeout and a disconnect can race for the same request. It must be resumed exactly
  once: removed from its table before it is resumed.
- `withTaskCancellationHandler` takes `isolation: self` explicitly (swiftlang/swift#92915); no
  actor-isolated closure is converted to a caller-isolated one. A cancelled wait returns at once, so a
  loop around it must stop on cancellation instead of spinning to its timeout.
- Release builds differ from debug. A change here is not done until the optimised build has passed the
  hardware check (`hardware-verify`).

## 4. A write sends exactly the bytes someone wrote

- Hex, base64 and utf8 decoding must reject what is ambiguous rather than guess: separators between
  digits, odd lengths, `0x` fragments. A decoder that is lenient about *encoding* and strict about
  *meaning* stays that way.
- The write policy (`checkWrite`) runs before anything else happens: no subscription, no connection
  work, no capture row of a write that never went out. Descriptor writes are checked against their
  characteristic. A new write path goes through it, and hides the tool while writes are disabled.
- The frame allowlist and denylist compare bytes and characteristic, not a display form.
- Is the payload within the negotiated maximum for the write mode?

## 5. Link and process lifecycle

- A link the peripheral or adapter drops must be reported on the next call (`disconnected`, with
  reason and time) and in `ble_status`, not as `not_connected`. A disconnect the agent asked for is
  not a loss.
- Shutdown (SIGTERM, SIGINT, EOF on stdin) must stop scans and connects that are still waiting for
  the adapter, flush the capture and answer every request already read, for up to the drain timeout.
- Is a request written to stdout in full? A short write is not a complete write.
- Permission: `awaiting_permission` and a slow first start are not `unknown`.

## 6. Capture and replay are one contract

Captures are also fixtures for swift-dragoman (`CaptureLog`), and replay reads older ones.

- Does a new row keep every existing field's name and type? Nested values in `info` rows are fine
  because the reader skips them.
- An agent's marker (`"marker": true`) is never read as an event, whatever its `note` says. A file
  appended to by several runs restarts `t` at 0 each time. A cut-off last line is skipped with a
  warning; a broken line in the middle is an error with its number.
- Does `diff` compare services only when both captures recorded them, so old and new still compare?
- A replay must treat a frame the capture never sent as a divergence, not as an error in default mode,
  and as a failure naming the next recorded write in strict mode.

## 7. Device text is data

Names, 0x2901 descriptions and value text reach the model. Do they pass through `DeviceText` where they
enter the server? Is `hex` still the whole value? Does a new tool result or error message echo device
text raw? A capture or replay file is device text too.

## 8. The tool surface

- Every argument is a `ToolArgument`; no hand parsing. Unknown arguments, fractional numbers and
  malformed UUIDs are rejected naming the argument.
- Errors are `BLEError` cases with a stable `code` and a `hint` where there is a next step.
- Is the README tool table and count still true (`ReadmeConventionTests`)?

## Finishing

Before reporting, confirm each finding by running it: a hypothesis about ordering or identity is cheap
to check with a `FakeCentral` responder, a delay or a second device. Discard unconfirmed suspicions
silently rather than reporting them. For anything you then fix, apply the `verify-the-guard` skill.
