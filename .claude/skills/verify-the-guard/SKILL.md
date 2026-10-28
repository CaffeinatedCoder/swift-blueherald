---
name: verify-the-guard
description: Prove a guard actually fails without the thing it guards — revert the source fix, or seed the defect where there is no fix to revert. Use whenever adding a test alongside a bug fix or a new check in this repo, when a test replaces a convention, and before reporting the work as done.
---

# Verify the guard

A regression test that passes both with and without the fix is not a regression test. It is a test
that happens to pass, and it will keep happening to pass while the bug comes back.

The discipline is one extra step: **after the test goes green, revert the source change and confirm
the test goes red.** Then restore and re-run.

This matters more here than usual, because the tests run against `FakeCentral` and `ReplayCentral`,
which are scripted. A fake that never fails, never delays, or never reorders makes a race test pass
whatever the code does. The races in `BLESession` and `CoreBluetoothCentral` only show up when the
fake is made to misbehave on purpose (`FakeCentral` can delay or fail `setNotifications`, answer a
write after a delay, or drop a link).

## The loop

1. Write the test. Run it — it should **fail**, for the reason you expect. Read the failure
   message; if it fails for a different reason than the bug, the test is testing the wrong thing.
2. Apply the fix. Run it — it should pass.
3. **Revert only the source change**, keeping the test. Run again — it must fail.
4. Restore the fix. Run the full suite and confirm the count is back where it started.

Step 1 is often skipped when the fix is already written. Step 3 recovers the same guarantee after
the fact, so do step 3 always, even when you did step 1.

## Reverting cleanly

```bash
SCRATCH=$(mktemp -d)
cp Sources/BLEMCPCore/BLESession.swift "$SCRATCH/"
# remove just the fix, then:
swift test --filter BLEMCPCoreTests
cp "$SCRATCH/BLESession.swift" Sources/BLEMCPCore/
```

Revert the **source**, never the test. `git checkout --` on a file that also holds unrelated work
loses it, so copy aside instead. `git checkout -- .` does not undo a `git mv`: the rename is staged,
so the tree is restored to the renamed state. Use `git reset --hard` only on a tree you have
committed or copied.

## What counts as failing for the right reason

- **Right:** the asserted value is the wrong one (read #2 returned read #1's value, a notification
  from before the write became the reply); an `#expect(throws:)` reports no error; a capture is
  missing the row; a count differs.
- **Wrong:** a crash, a compile error, a timeout of the test itself, or a failure in a *different*
  test. A compile error usually means the test depends on API introduced by the fix — restructure
  it to exercise behaviour that exists either way, or accept that it is a feature test rather than a
  regression test and say so.

For a race, one red run is not proof and one green run is not either: run the test repeatedly (loop
`swift test --filter <name>` in the shell) before and after, in debug and with `-c release`, and report
the failure rate. A test that failed
"in about a third of release runs" before its fix and in 0 of 12 after is a claim; "passes" is not.

## Ways a guard passes vacuously

Check these before believing a green run:

- It iterated an empty list. Every assertion that loops over a discovered set (tools, characteristics,
  rows, devices) needs a floor assertion on how many items it found.
- It asserted on something both the correct and the broken path produce: a value that is its own
  decoded form, one device where the bug needs two, one service where the bug needs two with the same
  characteristic UUID, one notification where the bug needs an earlier one.
- The fake answered instantly, so a timeout, an overtaking reply or a cancelled wait never happened.
- It read a stale build product or a previously written capture file instead of the one just made.
- It greps for a phrase that no longer occurs because the phrase was reworded.

## When the guard is a convention test

There is no fix to revert; the counterfactual is to **seed the defect**: add a tool without its
README row, change the README count, rename a capture field, drop a `peripheral` key from a row, and
confirm the convention test names it. Match structure (a table row, a JSON key), not a substring
that also occurs in prose. `Tests/BLEMCPServerTests/ReadmeConventionTests.swift` is the model.

## Tests that legitimately pass either way

Tests pinning behaviour that was already correct, and tests protecting against a future
over-correction, are worth having. Do not count them as evidence that a fix works, and say which they
are when reporting.

## Reporting

State the counterfactual result explicitly: "reverting the fix makes these three tests fail, with
this output". "Added a test" says nothing about whether the bug is caught. When several fixes land
together, revert them all at once and confirm the failure count matches the number of guards.
