# App Self-Update — Design (2026-07-14)

Status: **proposed** (spec-first — no code until this is approved).
Relates to: SPEC §31 (Distribution), §27.7 (firmware OTA — the pattern this mirrors).

---

## 1. Goal

Let the **app** update itself from GitHub Releases, the same way the device
firmware already does (§27.7): the app checks for a newer published app version
and — on the platforms that allow it — downloads and installs it in place.

This removes the "rebuild + reinstall by hand" loop that just bit us (a stale
debug build silently reverting the UI), and gives real users a one-tap update
path without an app store.

## 2. Scope

| Platform | This sprint | How it installs |
|----------|-------------|-----------------|
| **Android** | ✅ full in-app update | download signed APK → hand to the OS package installer (user taps "Install") |
| **Linux** | ✅ full in-app update | download new **AppImage** → replace the current file → relaunch |
| **Windows** | ⚙️ **scaffold only** | check + download wired; the actual install (swap/restart) is a clearly-stubbed "not yet" |
| iOS / macOS | ❌ out of scope | App Store / notarization; iOS cannot self-install |

**Non-goals (this sprint):** delta/differential updates (we download the full
artifact), forced/mandatory updates (update is always user-initiated), and any
app-store path.

## 3. Architecture — two parts

The firmware OTA is the template. Two independent pieces:

### Part A — App-release pipeline (CI)

A new GitHub Actions workflow in `idl0-app`, **`app-release.yml`**, triggered on
a version tag. Mirrors `firmware-release.yml`:

- **Version of record = the git tag** (leading `v` stripped), exactly like
  firmware. CI stamps the build from the tag (`flutter build --build-name=<ver>`),
  so `package_info_plus` at runtime reports the tag.
- Builds per platform and publishes to **GitHub Releases** (this repo):
  - **Android:** `flutter build apk --release` (signed, see §6) → `idl0-app-v<ver>.apk` + `.sha256`
  - **Linux:** `flutter build linux --release` → package as AppImage (`appimagetool`) → `idl0-app-v<ver>-x86_64.AppImage` + `.sha256`
  - **Windows:** `flutter build windows --release` → zip the bundle → `idl0-app-v<ver>-windows-x64.zip` + `.sha256` (published, not yet consumed)
- **Stable vs beta** map onto the GitHub prerelease flag (a `-beta`/`-rc` tag
  suffix → prerelease), identical to firmware channels.
- **Exactly one asset per platform per release**, versioned filenames — the
  same asset-contract discipline the firmware workflow enforces.

### Part B — In-app updater

Mirrors the firmware update surface (`firmwareUpdateProvider` + §27.7 UI):

- **`AppReleaseCatalog`** — queries this repo's Releases API for the channel's
  latest release and selects the asset for the current platform
  (`Platform.isAndroid` → `.apk`, `isLinux` → `.AppImage`, `isWindows` → `.zip`).
  Shares a GitHub-Releases client with the firmware catalog (generalized) rather
  than duplicating it.
- **`appUpdateProvider`** (parallel to `firmwareUpdateProvider`): compares the
  running app version (`package_info_plus`) to the channel's latest and yields
  `idle / checking / upToDate / updateAvailable / checkUnknown`. Same live
  re-derivation discipline we just added for firmware (never a stale verdict).
- **UI:** a new **Settings → App updates** section (sibling of the Firmware
  section), reusing the "update available vX → vY" card + channel picker +
  "Check now" + auto-check toggle. On desktop it can also surface in an About
  area later; Settings is the canonical home.

## 4. Per-platform install detail

- **Android.** Download the APK to app-specific storage, then launch an install
  intent through a small platform channel + a `FileProvider` (share the APK URI
  with the OS installer). Requires the `REQUEST_INSTALL_PACKAGES` permission;
  on Android 8+ we check `canRequestPackageInstalls()` and, if off, route the
  user to the "install unknown apps" settings screen once. The OS installer does
  the actual replace — and **enforces the signature match** (see §6), which is
  the integrity gate.
- **Linux (AppImage).** The running AppImage's file can be replaced on disk
  while it runs (the process holds the open inode). Download the new AppImage
  next to the current one, `sha256`-verify, `chmod +x`, atomically replace the
  current file, and prompt the user to relaunch (or `exec` the new one). No
  install step, no root.
- **Windows (scaffold).** The check + download land; the install path is a
  stub that surfaces "downloaded — manual install for now" and opens the file
  location. Full Windows install (in-place swap via a helper, or MSIX) is a
  later phase.

## 5. Version of record & comparison

- The git tag is authoritative; CI builds with `--build-name=<tag-without-v>`.
- At runtime, `package_info_plus` reports that version; we parse both ends as
  semver (`pub_semver`) and offer an update only when hosted `>` current — the
  exact rule §27.7 uses for firmware, including the "device/app ahead of
  channel → informational, never a downgrade" case.
- **New dependency:** `package_info_plus` (add if not already present).

## 6. Android signing (the one real prerequisite)

Self-update requires the update APK to be signed with the **same key** as the
installed app, or Android rejects it. Today the app builds with the debug key.
We will, as part of the pipeline phase:

1. Generate a **release keystore** once (`keytool`), kept **out of git**.
2. Store it (base64) + the store/key passwords + alias as **GitHub Actions
   secrets**.
3. Wire `android/app/build.gradle` release signing to read them from
   `key.properties` (gitignored) in CI.

I'll script/walk this through — nothing for you to prepare in advance.
(AppImage GPG signing is optional and deferred; the `sha256` sidecar is the
integrity check there.)

## 7. Security summary

- **Android:** OS-enforced signature match is the gate; optional `sha256`
  pre-check.
- **Linux:** published `sha256` sidecar verified before the swap; GPG optional,
  deferred.
- **Windows:** deferred with the install path.

## 8. Phasing (the implementation plan will expand this)

1. **Release pipeline + keystore + shared version-check + Settings UI.** All
   three platforms build & publish; the "update available" card shows
   everywhere; **Android install wired**. (Windows/Linux install stubbed.)
2. **Linux AppImage install** (download → verify → swap → relaunch).
3. **Windows install** (scaffold → full, later).

Phase 1 is the bulk (CI + signing + packaging + UI). 2 and 3 are contained.

## 9. Alternatives considered

- **Notify + link only** (detect, open the release page, user installs by hand).
  Simpler — no signing/permission/packaging — but you asked for the full path;
  we keep this as the automatic *fallback copy* if a platform's install can't
  proceed (e.g. permission denied).
- **App stores / `in_app_update`** — Play-Store-only, rejected (GitHub-hosted,
  no store).
- **Sparkle / Squirrel / platform frameworks** — heavier and per-platform;
  GitHub Releases + a thin updater is lighter and consistent with the firmware
  OTA we already run.

## 10. Open decisions (your call before/while I write the SPEC section)

1. **Tag scheme.** Use `v<version>` tags in this repo for app releases
   (firmware lives in a separate repo, so no collision)? *Proposed: yes.*
2. **Channels.** Ship stable-only first, or stable/beta from the start (the
   firmware pattern is already built, so beta is nearly free)? *Proposed:
   stable + beta, independent of the firmware channel setting.*
3. **UI home.** New **Settings → App updates** section? *Proposed: yes.*
4. **Auto-check on launch** (like firmware) vs manual "Check now" only?
   *Proposed: auto-check on, same toggle pattern.*

---

## Appendix — Proposed SPEC change

On approval this lands as **SPEC §31.1 (App release pipeline)** and **§31.2
(In-app self-update)**, expanding the existing §31 Distribution table, plus a
one-line pointer from §27.7 noting firmware OTA and app self-update share the
GitHub-Releases model. Disposition: **spec-first**.
