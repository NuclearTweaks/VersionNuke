# VersionNuke

AppStore++ style version picker — long-press Get/Update in the App Store to choose which version to install. Pin an app to a known-good build before an update breaks it.

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).

## Development

Org-standard scaffold — pipeline lives in `$ORG/.github` (reusable `tweak-ci.yml`).

* Local sim loop: `tools/sim-test.sh VersionNuke` from the workspace root (Mac + JB-13mini; CI never builds for sim).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.version-nuke` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).
