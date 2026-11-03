# VersionNuke

**Pin App Store apps to the version you're on — updates can never move you off a known-good build.**

An update just broke your favorite app? Before that next "helpful" auto-update lands, pin the app: Settings → VersionNuke → app → **Pin to vN.N.N**. From then on the App Store treats the pinned build as *the store's latest* for you —

* no more update offers for that app,
* auto-update resolves to the pinned version id (effectively a no-op),
* even a manual Update reinstalls the pinned build instead of the new one,
* and the repair/redownload path gets the same answer.

Unpin returns the app to normal update behavior immediately — changes apply on the next update check, no respring.

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).

## How it works

iOS 27 decides *which build* to install inside `AppStoreDaemon` (process `appstored`) from version identifiers flowing through four objects (every hook target below was verified against the live iOS 27 `AppStoreDaemon` with a runtime class/method probe — exact type encodings too):

* `-[ASDAppLedgerItem initWithBundleID:bundleVersion:itemID:versionID:installDate:lastLaunchDate:]` — the daemon's record of **what is installed**, including the external version id. VersionNuke observes every ledger read into its own learned ledger, so it always knows each app's exact current build and its store version id (shown in Settings when available).
* `-[ASDApplicationMetadata externalVersionIdentifier/bundleVersion/shortVersion]` — **what the store says to install**. For a pinned app these answer with the pinned build.
* `-[ASDManagedApplicationRequestOptions externalVersionIdentifier]` — repair / managed-redownload path, same lie.
* `-[ASDSoftwareUpdate externalVersionIdentifier]` — update-list entries for pinned apps resolve to the pinned build.

Pins live in the tweak's preference domain (`com.nucleartweaks.version-nuke`) and the daemon reloads live via a Darwin notification. With no pins set, nothing is changed anywhere.

## Settings

* **VersionNuke enabled** — global kill switch.
* **Pin app versions** — list of installed apps with their current version; the per-app page shows what the daemon learned (build + store version id) and offers the pin switch.
* **Advanced overrides** — force a version string or an explicit store version id (only installable if Apple's CDN still serves that build).

## Verification status (read this)

Verified on the iOS 27 JB simulator: clean build, correct class/selector existence **against the real AppStoreDaemon binaries** (probe-confirmed method lists + type encodings), deb + pane packaging. **Not yet verified end-to-end**: a suppressed update on a real device. `appstored` does not exist in the simulator runtime, so the daemon-side behavior can only be exercised on a device (or the vphone VM, pending). The design follows the AppStore++ mechanism adapted to the modern ASD architecture, and every lie degrades to the truth on any unexpected shape (no pin = zero behavior change; unpinned apps untouched).

A long-press "pick a version" menu inside the App Store app itself (classic AppStore++ UX) is a planned v1.x; it requires probing the device-only AppStore.app binary.

## Development

Org-standard scaffold — pipeline lives in `NuclearTweaks/.github` (reusable `tweak-ci.yml`).

* Compile/packaging loop: `tools/sim-test.sh VersionNuke` (Mac + JB-13mini).
* Hook-surface probe: `tools/probes/VVProbe` (dumps the AppStoreDaemon version surface live).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.version-nuke` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).
