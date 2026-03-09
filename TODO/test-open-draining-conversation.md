# testOpenDrainingConversation TODO

Last updated: 2026-03-10

## Current status

- [x] Reproduced locally on current `master`.
- [x] Recorded the failing assertion and repro command.
- [x] Confirmed the latest `OpenCANTests` run still has this as the only failing test.
- [ ] Root-cause the mismatch between expected queued user message count and actual transcript state.
- [ ] Decide whether the regression is in app logic or the test expectation.
- [ ] Land a fix and rerun `OpenCANTests/AppStateTests/testOpenDrainingConversation`.

## Repro

```bash
xcodebuild test -scheme OpenCAN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenCANTests/AppStateTests/testOpenDrainingConversation
```

## Failure

- Failing test: `OpenCANTests.AppStateTests/testOpenDrainingConversation`
- Current failure site: `Tests/AppStateTests.swift:1153`
- Assertion:

```swift
XCTAssertEqual(appState.messages.filter { $0.role == .user }.count, 2)
```

- Observed value in the latest repro: `1`
- Expected value in the test: `2`

## Notes

- This failure reproduces even when running the single test in isolation.
- The latest full `OpenCANTests` run executed 115 tests with exactly 1 failure: this test.
- The new pre-release licensing and About UI changes did not touch `AppState` or this test path; treat this as a separate existing regression until proven otherwise.
