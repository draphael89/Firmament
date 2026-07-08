# M0 Operator Checklist — the five hardware/account legs of the Definition of Done

Everything machine-verifiable in [the M0 plan](plans/2026-07-08-001-feat-firmament-v1-1-plan.md) is green
(93 package tests, 50/50 crash kills, all app targets building). These five items need the
operator, physical devices, and Apple account plumbing. Order matters — item 1 unblocks 2–4.

## Status (2026-07-08)

**R10, the M0 acceptance criterion, is satisfied on real hardware**: an airplane-mode phone
capture transcribed on-device, synced to the Mac when connectivity returned, and
`firmament verify` exits 0 with both chains intact; the Vault renders both devices' notes;
the 50-kill crash suite passes in CI.

| # | Item | Status |
|---|---|---|
| 1 | Apple plumbing | ✅ team YF9662K2Y4, container, App Group, both devices signed and installed |
| 2 | Action Button latency (locked phone) | ⬜ open — the KTD11 gate |
| 3 | Mac panel + hotkey | ✅ ⌥Space → panel → capture → real transcription → Vault |
| 4 | Two-device sync round-trip (airplane mode) | ✅ offline capture + transcript synced; both chains verify |
| 5 | One week of daily use | ⬜ in progress |

Six defects surfaced only on hardware or on inspection, and are fixed: the realtime audio-tap
executor assertion (capture crashed on first buffer), the unretained `CKSyncEngine` delegate
(sync was a silent no-op — nothing ever uploaded), the iOS ledger living at the App Group root,
the missing `UIBackgroundModes = [audio]` (the Action Button path could never have recorded
while backgrounded), the latency instrumentation anchoring at `start()` rather than at process
spawn (a cold press would have reported as fast as a warm one), and — the worst of them —
launch reconciliation adopting the *live* recording's partial file, which destroyed the very
capture it then filed as a recovery artifact.

That last one was latent precisely because the Action Button path had never run. It is a race
between `launchSequence()` and a capture that starts before reconciliation finishes: certain on
the intent path (`perform()` starts the recorder while the queued `launchSequence()` waits for
the MainActor), and reachable on the Mac too, where ⌥Space is live during a launch fold and a
first-run WhisperKit model download. `AudioFileStore` now tracks the temp paths this process is
writing, and only unowned partials are adoptable.

Open signal for item 2: transcripts of app-UI captures have begun mid-phrase, and one 11-second
utterance recorded as 9.8 s. That is suggestive of start-of-capture clipping but does not
decide KTD11 — the Action Button path is separate and still unmeasured.

## 1. Apple plumbing (one-time)

- [ ] In the Apple Developer portal: create the app IDs (`com.davidraphael.firmament`,
      `com.davidraphael.firmament.ios`, `.ios.FirmamentWidgets`), the iCloud container
      `iCloud.com.davidraphael.firmament`, and the App Group `group.com.davidraphael.firmament`.
- [ ] In Xcode, set your team on all three targets (`app/Firmament.xcodeproj`); signing is
      `Automatic`. Entitlement files are already in place (`app/Mac/`, `app/iOS/`, `app/iOSWidgets/`).
- [ ] Build & run the Mac app once; grant microphone permission.
- [ ] Install the iOS app on your iPhone; open it once in the foreground (mic permission must be
      granted before the Action Button path can record in the background).

## 2. U1 latency spike (gates KTD11's final shape)

The capture now instruments itself, so this is one physical press and no stopwatch. Every
phone capture stamps two numbers into its `capture.audio` payload `context`:

| field | measures |
|---|---|
| `processAgeAtStartMS` | process spawn → `start()`: launch, App Intents resolution, `PhoneModel` init |
| `startLatencyMS` | `start()` → first audio sample: audio-session activation, engine start |

A **cold** press (the case SPEC §9.2 budgets) is one where `processAgeAtStartMS` is small —
single-digit seconds — meaning iOS spawned the process to service the intent. There,
`press-to-first-sample ≥ processAgeAtStartMS + startLatencyMS`. It is a lower bound: the gap
between the physical press and the spawn is not observable from inside the process. On a
**warm** press (app already resident, `processAgeAtStartMS` in the minutes) the first term is
meaningless and `startLatencyMS` alone is the cost.

Measuring only `startLatencyMS` would have understated the cold path by the entire launch
cost and wrongly passed KTD11.

- [ ] Assign the "Firmament Capture" shortcut to the Action Button
      (Settings → Action Button → Shortcut). Enable Live Activities for Firmament.
- [ ] Open the app once after install (microphone permission must already be granted).
- [ ] **Lock the phone.** Press the Action Button, speak immediately, press again to stop.
- [ ] With the phone attached, run `app/scripts/action-button-latency.py`. It pulls the phone's
      own ledger, finds the press, and prints the verdict (exit 0 within budget, 1 over, 2 if
      the press hasn't landed yet).
- [ ] If it reports **over budget** (cold sum > 2000 ms), KTD11 flips to the fallback — a
      persistent warm audio session (plan Risks) — and the finding goes to a spec conversation.

## 3. Mac smoke checklist (U5)

- [ ] ⌥Space opens the capture panel over a fullscreen app on another Space.
- [ ] The panel does not steal the frontmost app's focus (type in another app, then hit ⌥Space).
- [ ] The panel accepts keyboard input (Return stops) without crashing (macOS 26 `canBecomeKey`).
- [ ] Hotkey still fires after quitting and relaunching the app.
- [ ] Confirm ⌥Space is unclaimed on this machine (no input-source switcher owns it).
- [ ] A capture appears in `~/Firmament/Vault/journal/<today>.md` with its transcript
      (first transcription downloads the large-v3 model — expect a wait, then <1.5s per minute
      of audio; the stop→transcript latency is logged).

## 4. R10 sync round-trip (U12/U10)

- [ ] Both devices signed into the same (ideally dedicated test) Apple ID; CloudKit container
      reachable (first build creates the Development-environment schema on first save).
- [ ] Phone in airplane mode: capture a voice note on a walk. Confirm it transcribes on-device.
- [ ] Leave airplane mode; wait for sync. On the Mac: the capture and its transcript appear in
      the Vault, audio playable from `~/Library/Application Support/Firmament/media/audio/`.
- [ ] `swift run --package-path app/FirmamentKit firmament verify` → exit 0, both chains intact.

## 5. The real bar (SPEC §14)

- [ ] One week of real daily voice notes without touching Xcode. Watch for: adopted
      "interrupted" captures you didn't expect (reconciler log), transcription parking,
      sync integrity alarms in the menu bar.

When all five are checked, M0's Definition of Done is fully satisfied; M1 (Recall) planning
starts with its own enrichment pass against the same plan artifact.
