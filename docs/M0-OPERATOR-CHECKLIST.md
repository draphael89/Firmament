# M0 Operator Checklist — the five hardware/account legs of the Definition of Done

Everything machine-verifiable in [the M0 plan](plans/2026-07-08-001-feat-firmament-v1-1-plan.md) is green
(84 package tests, 50/50 crash kills, all app targets building). These five items need the
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

Three defects surfaced only on hardware and are fixed: the realtime audio-tap executor
assertion (capture crashed on first buffer), the unretained `CKSyncEngine` delegate (sync was
a silent no-op — nothing ever uploaded), and the iOS ledger living at the App Group root.

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

- [ ] Assign the "Firmament Capture" shortcut to the Action Button
      (Settings → Action Button → Shortcut).
- [ ] From a **locked** phone, press the Action Button; speak immediately.
- [ ] Measure press-to-first-captured-sample (compare the utterance start against the saved
      audio; the capture's `occurredAt` and the file are in the App Group container).
- [ ] Record the number in the plan's U1 verification note. If the first ~2s are lost, the
      fallback is a persistent warm audio session (plan Risks) — flag it before building on KTD11.

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
