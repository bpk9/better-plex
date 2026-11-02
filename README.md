# better-plex

A small native iPhone/iPad app for browsing your Plex library and manually downloading original movies, episodes, and seasons. Inspired by better-YouTube's native dark interface, with a warm gold accent.

Connects directly to your **existing Plex Media Server**. There is no companion service, scheduler, subscription watcher, or automatic download rule.

## Use

1. Open **Account → Sign in with Plex**. Complete Google or Plex sign-in in your default browser, then return to better-plex and select a server. Alternatively enter a server URL and token under **Connect manually**.
2. Choose a movie library or TV library. Search filters the selected library. Open a show to see its seasons and episodes.
3. Tap **Download movie**, **Download episode**, or **Download season**. Review the size and selected titles, then confirm. When multiple versions exist, individual titles let you choose a version; season downloads use the first version of each episode.
4. Use **Downloads** to pause, resume, retry, play, export to Files/another player, or remove local files. Completed files remain available without a server connection or Plex sign-in.

Two files transfer at a time. Downloads are Wi-Fi only by default; Account can enable cellular for new transfers. Transfers, metadata, and completed files persist across launches. iOS controls background execution; force-quitting interrupts transfers. Reopen and tap Resume when needed. Resumed requests retain their original network setting.

The app saves originals, without transcoding. AVKit plays supported local formats; MKV and unsupported codecs can be exported to a compatible player using **Save / Open**. There is no online streaming in this version. Plex's server access and download permissions apply. A forbidden download produces an error and does not try another endpoint to bypass it.

Multi-part movies save each part separately. Existing parts are skipped; failed or paused entries can be retried from Downloads. Files are also visible under **Files → On My iPhone → better-plex → Downloads**. Removing a local download never deletes media on Plex.

## Playback history

Version 1.1 syncs playback inside better-plex with the original Plex server and account. Before playback, it fetches the current resume position; the native player reports progress about every ten seconds, on pause/resume, and on exit. Plex decides when a title counts as watched using its server settings. Finishing a file also marks it watched locally.

Offline checkpoints are saved immediately and survive app restarts. They retry on network recovery, app activation, every thirty seconds while the app is running, or **Account → Sync playback history now**. iOS may suspend the app; reopen it to finish pending sync. Replayed timeline updates include their original timestamp and `offline=1`. A newer `lastViewedAt` reported by Plex takes precedence over an older offline checkpoint; otherwise an unsent local checkpoint is retained. A successful response acknowledges only the exact revision sent, so playback advancing during a request cannot lose the newer checkpoint.

Watch state is scoped to the server and Plex user ID. When Plex cannot identify a manually supplied token, it is scoped to that connection instead; changing that token does not send the old history under a different credential. Disconnect pauses history uploads. Existing downloads are associated with the active account when first played after this update.

Library cards, episode rows, details, and Downloads show watched/resume state. Open a title's details or its Downloads menu to **Mark watched / Mark unwatched**. These manual actions change watched status; they do not invent a playback-history session. External players cannot report progress back to better-plex, so use the manual action after watching an exported file. Multi-part files keep a separate local resume point for each part; automatic whole-title sync is disabled for those files to avoid sending an incorrect position. Mark the movie watched manually after all parts.

## Build

Version 1.0.1 opens sign-in in the full default browser instead of an embedded browser sheet, avoiding the embedded Google sign-in keyboard/autofill interaction. The pending Plex PIN is kept in Keychain until completion, cancellation, or expiry. Returning to the app checks sign-in immediately, even after the app has restarted. **Open sign-in browser** reopens the same attempt; **Check sign-in** retries a temporary connection failure. Cancelling prevents a later browser completion from signing the app in.

Open `ios/BetterPlex.xcodeproj`, select **BetterPlex**, and choose an iPhone simulator. No third-party dependencies.

For your phone, sign into your Apple developer account in **Xcode → Settings → Accounts**. Set your signing team in the ignored `ios/Config/Local.xcconfig` (see `Local.example.xcconfig`). Then:

```sh
bash scripts/install-iphone.sh YOUR_DEVICE_ID
```

Find paired devices with `xcrun devicectl list devices`. Keep the bundle ID and signing team stable when updating an installed copy. This is a development app, not an App Store/TestFlight release; development profiles expire and require reinstallation.

## Verification

The local test fixture imitates Plex only for simulator tests. It is **not** a companion server or runtime requirement. Give it an MP4 you have locally:

```sh
bash scripts/test-simulator.sh SIMULATOR_ID /path/to/test.mp4
```

Use a fresh/dedicated simulator for a complete repeatable test run. Simulator-only launch environment `PLEX_TEST_URL` selects this fixture; the override is compiled out of physical-device builds. The fixture tests server authentication headers, pagination, metadata, original-file downloads, season selection, pause/resume, persistence, native playback, and a 403 permission error. Tests are ad-hoc signed so the iOS simulator Keychain works.

The script also starts `auth-fixture-server.py` on loopback port 18766. `PLEX_AUTH_TEST_URL` is likewise simulator-only. Two additional UI tests passed for version 1.0.1: full-browser text entry, returning to the app, pending sign-in restoration after termination, and cancellation followed by a late browser authorization. They use a local fake account; they do not submit Google credentials.

Validated on November 1, 2026 with Xcode 27.2: simulator and unsigned iPhone builds succeeded; four UI tests passed, including offline playback after disconnect. All four completed fixture downloads matched the original MP4 by SHA-256, including the paused/resumed transfer. Plex's live PIN creation/polling endpoints also responded successfully. Actual Plex account authorization and a real-library download still require signing in. A signed development build was also provisioned and installed on an iPhone.

Version 1.1 verification: nine focused history tests cover persistence, retry, account isolation, stale-update conflicts, revision-safe acknowledgements, watched operations, live stop events, and multi-part handling. The simulator player integration test resumed at the server’s 12-second checkpoint, sent live progress, then recorded offline progress and replayed it after relaunch. These use the local fixture; no real Plex history was modified during testing.

## Implementation

- `PlexAPI.swift`: Plex PIN authorization, resource discovery, direct/manual server connections, paginated library requests.
- `Models.swift`: Plex responses and Keychain storage.
- `PlaybackHistory.swift`: account-scoped checkpoints, durable sync outbox, Plex timeline/watched operations, and native-player tracking.
- `Downloads.swift`: persistent queue, background URLSession transfers, resume data, space checks, file validation, and local removal.
- `Views.swift`: library, show/season detail, download review, offline library, player/export, and account settings.

Account/server tokens live in the device Keychain and are sent in request headers. The queue manifest has no tokens. OS resume data may include request credentials, so it is kept in protected Application Support storage, excluded from backups. Disconnect pauses active transfers and clears this app's credentials. Downloads are also excluded from backups.

HTTP is supported for direct LAN servers, which requires an ATS exception; use HTTPS server connections when available. Discovery prefers HTTPS and tries local/direct connections before relays at the same security level. No TLS certificate-validation bypass is used.

Plex references: [official authentication flow](https://forums.plex.tv/t/authenticating-with-plex/609370) and [Plex Media Server API](https://developer.plex.tv/pms/) (library pagination, resources, and `download=1` media-part requests).
