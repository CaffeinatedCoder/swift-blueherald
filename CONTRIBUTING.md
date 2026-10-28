# Contributing

Issues and pull requests are welcome. For a security report, follow [SECURITY.md](SECURITY.md)
instead; please don't open a public issue for those.

## Getting set up

```bash
swift build
swift test            # no Bluetooth hardware needed
```

Requires macOS 26 and Swift 6.4 or later (Xcode 27). [AGENTS.md](AGENTS.md) is the architecture and rules guide
(layers, concurrency rules, the capture-format contract); read it before changing `BLESession`,
`CoreBluetoothCentral`, the capture code or a tool.

The tests run against `FakeCentral` and `ReplayCentral`, so they cannot cover `CoreBluetoothCentral`.
A change there, or to actor, continuation or cancellation code anywhere, is checked against a real
peripheral with a **release** build ([hardware check](AGENTS.md#hardware-check)). Debug builds have
passed while release builds crashed.

Before opening a PR, all of these pass:

```bash
swift test
swift test -c release
swift test --sanitize=thread
swift format lint --strict -r Sources Tests Scripts Package.swift
```

## The quality bar

This server's characteristic failure is not a crash. It is an answer that looks right: a read that
returns the previous read's value, a notification taken for the reply to a write it preceded, a hex
string with separators written as bytes nobody typed, a capture whose second device replays as the
first. Nothing throws, and the agent builds its next decision on it, or the hardware does.
Everything below exists because of that failure mode.

**A bug fix needs a regression test, and the test must be proven to work.** Write the test, watch it
fail, apply the fix, watch it pass, then *revert the fix and confirm the test fails again*. A test that
passes both with and without the fix is not a regression test. Races are proven by failure rate in
both debug and release, not by one run. See
[`.claude/skills/verify-the-guard`](.claude/skills/verify-the-guard/SKILL.md).

**Changes to request/reply correlation, identity, the write path, link or shutdown handling, or the
capture format get a semantics review.** The lens is written down in
[`.claude/skills/ble-semantics-review`](.claude/skills/ble-semantics-review/SKILL.md) and comes from
the defects the bug sweeps found.

**Prefer a loud failure to a silent one.** Where the server cannot represent something correctly, it
fails with a `code` and a `hint` an agent can act on. It never returns a plausible value that is wrong,
and never sends bytes nobody wrote.

**Prefer a test to a convention.** A mechanical rule belongs in the suite, not in a document nobody
re-reads. `ReadmeConventionTests` holds the README's tool table and count against the catalogue.

**A real device is the authority on CoreBluetooth.** The fakes encode what we believe it does. A change
to `BlueHeraldCoreBluetooth` is not done until `Scripts/hardware-smoke.swift` has passed with a release
build.

## Issues

Use the **Bug** or **Enhancement** form. The bug form asks whether the failure is silent or loud,
because that decides how urgent it is. Releases and longer themes are tracked as `epic` issues with the
work as sub-issues. A maintainer sets the `area/*` and `severity/*` labels when triaging, and a pull
request gets the same labels as the issue it closes.

Labels (the scheme is defined in [`.github/labels.json`](.github/labels.json)):

- **Type:** exactly one of `bug`, `enhancement`, `documentation`, `tests`, `chore`.
- **`area/*`:** every concern the change touches: `core`, `corebluetooth`, `replay`, `server`, `cli`,
  `capture`, `security`, `release`.
- **`severity/*`:** bugs only: `critical`, `high`, `medium`, `low`.
- **`silent`:** a bug that answers wrongly, or writes something unintended, without an error.
- **`breaking`:** changes a tool name, argument or result shape, an environment variable, or the
  capture format.
- **`needs-hardware`:** can only be verified against a real peripheral.
- **`stacked`** (PRs): the base is another open PR. Merge them in order.
- **`epic`, `roadmap`:** a release or theme whose sub-issues are the work; the roadmap holds the epics.

## Pull requests

- One concern per PR, with the reasoning in the description rather than only the diff: Problem,
  Change, Tests.
- Open with `Closes #n`, and carry the issue's labels and milestone. CI fails a PR with no type label,
  a bug with no severity, or no closing reference.
- Full suite green in debug, release and under ThreadSanitizer, and the format lint clean.
- A tool change updates the README table and count; a new failure gets an error case, a code and a test.
- Match the surrounding style. Comments explain *why*, especially where behaviour is load-bearing.

## Commit trailers

A fix commit says how the defect was found and what kind it is, as git trailers after the body:

```
Found-By: SW
Defect-Class: CORR
```

- `Found-By:` is `SW` bug sweep, `RV` code review, `HW` hardware check, `PR` probe, `CA` analyst,
  `IS` issue report, `US` user.
- `Defect-Class:` is `CORR` a reply paired with the wrong request or device, `IDEN` peripheral, service
  or characteristic identity, `ENC` encoding and parsing of values, `RACE` actor re-entrancy and
  callbacks, timeouts or cancellation racing, `LIFE` connect, link loss, shutdown and end of input,
  `CAPT` capture, replay or diff fidelity, `POL` write policy and limits, `TRUST` untrusted device
  text, `IO` the stdio transport, `PERM` Bluetooth permission and the relaunch.

`git log --format='%(trailers:key=Found-By,valueonly)' | grep . | sort | uniq -c` counts the finders.

## AI-assisted development

A substantial part of this codebase, including much of the concurrency work, the replay backend and the
test suite, was written with AI assistance, using [Claude Code](https://claude.com/claude-code). It is
stated plainly because people who point this server at their hardware should know how it is built, not
because anything about it is unusual.

- **Direction, architecture and acceptance are the maintainer's.** Design decisions, trade-offs and
  what merges are human calls. AI is a tool used under review, not an autonomous committer.
- **Nothing is accepted because it looks right.** Plausible-looking code is cheap to produce, so fixes
  are proven against the bug they claim to fix, and convention tests are proven by seeding the defect
  they claim to catch.
- **Hardware is checked by hardware.** A model cannot see CoreBluetooth misbehave in a release build;
  the smoke script on a real peripheral can.
- **The audit trail is public.** Commit messages record what was wrong, what an agent would have
  experienced and how the fix was verified, with the trailers above.
- **Code is judged on behaviour, not provenance.** A defect is a defect whoever typed it.

If you contribute with AI assistance, that is fine, and the same bar applies. Make sure you understand
and can defend what you submit, and that it is yours to contribute.
