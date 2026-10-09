# Updates

typebud updates itself from the GitHub Releases of `plyght/typebud`. A release
that supports updates carries a `manifest.json` signed with an Ed25519 key whose
public half is compiled into the app; nothing is installed unless it matches that
manifest.

**Updates are optional per build.** The public key is a build input
(`zig build -Dupdate-public-key=<64 hex>`), not part of the source tree. A build
without one (the default, and every release until the owner creates the key)
links the updater but never touches the network: Settings > System says
"Automatic updates aren't enabled for this build" with a **View Releases**
button, and the tray's "Check for Updates…" opens the releases page. A build
with a key checks every 6 hours and on **Check Now**, and only ever installs
releases whose signed manifest verifies. See [Enabling updates](#enabling-updates).

The code lives in `updater/`, a standalone Zig module with its own `build.zig`:

| Path | What |
| --- | --- |
| `updater/src/root.zig` | Public API (`Updater`) |
| `updater/src/github.zig` | Parses the releases API response and picks a release |
| `updater/src/manifest.zig` | Manifest format, signature check, downgrade and channel policy |
| `updater/src/platform.zig` | Install detection and artifact selection |
| `updater/src/plan.zig` | File-swap plans (pure functions) and the executor |
| `updater/src/apply.zig` | Extraction, per-platform install, relaunch, cleanup |
| `updater/src/http.zig` | HTTPS via `std.http.Client`: ETag requests, resumable downloads |
| `updater/src/state.zig` | `update-state.json` and the check schedule |
| `updater/src/release_key.zig` | The trusted public key, read from the build option `-Dpublic-key` (none by default) |
| `updater/src/test_keys.zig` | Test-only keypair. Its private key is public. Never use it for releases. |
| `updater/src/cli.zig` | `typebud-update-check`, used in CI |
| `updater/tools/keygen.zig` | Generates the signing keypair |
| `updater/tools/mkmanifest.zig` | Writes `manifest.json` (sizes + SHA-256) in CI |
| `updater/tools/sign.zig` | Signs `manifest.json` in CI |
| `src/updates.zig` | The app's side: schedule, check/download/apply, the "no key" mode |
| `src/update_hook.zig` | What the settings window and tray call; status strings |
| `.github/workflows/release.yml` | Build, sign and publish pipeline |

## How it works

```
 app start ──► cleanupAfterUpdate()        removes *.old, staging dirs, stale downloads
     │
 timer (msUntilNextCheck) or "Check now" in Settings
     │
     ▼
 GET api.github.com/repos/plyght/typebud/releases   (If-None-Match: <etag>)
     │  304 → reuse the cached candidate          200 → pick newest eligible release
     ▼
 newer than the running version?  no → up_to_date (no further requests)
     │ yes
     ▼
 GET manifest.json + manifest.json.sig  →  Ed25519 verify  →  parse  →  policy checks
     │                                                       (newer, channel, tag == manifest)
     ▼
 .available{ version, notes, size, support }   ← the settings UI shows this
     │ user clicks "Update"
     ▼
 download(progress)   background thread; resumes with HTTP Range; exits when done
     │                verifies size + SHA-256 from the signed manifest
     ▼
 applyAndRelaunch()   re-verifies SHA-256, swaps files atomically, starts the new
 or applyOnQuit()     version (the app then quits) / installs when the app quits
```

### Checking

* **Source:** `GET https://api.github.com/repos/{owner}/{repo}/releases?per_page=15`.
  Drafts are always skipped. A release counts as a pre-release if GitHub
  marks it as one or its tag has a semver pre-release part (`v0.3.0-beta.1`).
  Pre-releases are only offered on the `beta` channel. A release is only
  considered if it has both `manifest.json` and `manifest.json.sig` assets,
  and only asset URLs under `https://github.com/{owner}/{repo}/releases/download/`
  are used.
* **Rate limits:** the response's `ETag` goes into `update-state.json` and is
  sent back as `If-None-Match`. An unchanged release list returns
  `304 Not Modified`, which doesn't count against GitHub's 60 requests per
  hour unauthenticated limit, and the cached candidate is reused. Manifests and
  artifacts come from `github.com/.../releases/download/` (a CDN redirect)
  rather than the API.
* **Schedule:** automatic checks run at most once every 6 hours, plus a random
  0 to 45 minute delay so clients started at the same moment don't hit GitHub
  together. A failed check (offline) also waits for the next slot. Checks the
  user starts from the settings window (`check()`) skip the schedule. They are
  still conditional requests, so they're cheap.
* **Idle cost:** no updater thread or socket exists between checks. The app
  calls `msUntilNextCheck()` and arms a one-shot timer on its own event loop.
  Each check or download creates its own `std.http.Client` and closes it
  afterwards (`keep_alive = false`).

### Manifest

```json
{
  "schema": 1,
  "product": "typebud",
  "version": "0.2.0",
  "channel": "stable",
  "artifacts": [
    { "platform": "macos-universal", "name": "typebud-macos-universal.zip", "size": 12345678, "sha256": "…64 hex…" },
    { "platform": "windows-x86_64", "name": "typebud-windows-x86_64.zip", "size": 9876543, "sha256": "…" },
    { "platform": "linux-x86_64-appimage", "name": "typebud-linux-x86_64.AppImage", "size": 11223344, "sha256": "…" },
    { "platform": "linux-x86_64-tarball", "name": "typebud-linux-x86_64.tar.gz", "size": 8765432, "sha256": "…" }
  ]
}
```

`manifest.json.sig` holds the 64-byte Ed25519 signature as lowercase hex (128
characters and a newline). The signed message is
`"typebud-update-manifest-v1\n" ++ <manifest.json bytes>`. The prefix keeps a
typebud manifest signature from being valid for any other kind of message.

The updater verifies the signature before it parses anything. It then
requires `schema == 1`, `product == "typebud"`, a valid semver `version` equal
to the release tag, known `platform` keys whose `name` is that platform's fixed
artifact name, and lowercase 64-character SHA-256 values.

Platform keys and artifact names: `macos-universal` → `typebud-macos-universal.zip`,
`windows-x86_64` / `windows-aarch64` → `typebud-windows-<arch>.zip`,
`linux-<arch>-appimage` → `typebud-linux-<arch>.AppImage`,
`linux-<arch>-tarball` → `typebud-linux-<arch>.tar.gz`.

### Installing

The swap is a list of steps computed by pure functions in `plan.zig`
(`macSwapPlan`, `windowsReplacePlan`, `appImagePlan`, `dirSwapPlan`). The
executor runs them through a small filesystem interface. If a required step
fails, it undoes the completed steps in reverse order. All renames happen
inside the directory that holds the install, so they stay on one filesystem
and are atomic.

| Platform | Install detection | What happens |
| --- | --- | --- |
| macOS | Executable at `<dir>/<Name>.app/Contents/MacOS/…` (`/Applications`, `~/Applications`, anywhere writable) | Creates `<dir>/.typebud-update-<rand>/`, unpacks with `/usr/bin/ditto -x -k` (keeps extended attributes, symlinks and signatures), checks `Contents/Info.plist` and runs `codesign --verify --deep --strict`. Then removes `com.apple.quarantine` from the new bundle (we downloaded and verified it ourselves) and swaps: `Name.app → .Name.app.old-<rand>`, new → `Name.app`, deletes the backup. Relaunches with `open -n`. |
| Windows | Directory of the running `.exe` (normally `%LOCALAPPDATA%\Programs\typebud`) | Unpacks the zip into `.typebud-update\` in the install dir. For each file: `x → x.old` (a running exe or loaded DLL can be renamed but not overwritten), then new file → `x`. Relaunches the exe. `cleanupAfterUpdate()` deletes `*.old` on the next start. Other files, such as user data, stay. |
| Linux AppImage | `$APPIMAGE` | Copies the AppImage to `.<name>.update` next to `$APPIMAGE`, sets mode 0755, then `rename()`s it over `$APPIMAGE`. The running AppImage keeps its open inode. |
| Linux tarball | Directory of the executable, **only if it contains `.typebud-install`** | Unpacks into `.typebud-update-<rand>/` next to the install dir, checks for the marker and the executable, then swaps directories as on macOS. |
| Package manager | `/usr/…`, `/nix/store`, `/gnu/store`, `/snap`, `/app` (Flatpak), `$FLATPAK_ID` or `$SNAP` set, Homebrew Caskroom, `WindowsApps`, Scoop, Chocolatey | No self-update. `support = .managed_by_package_manager`, and the UI says "managed by your package manager". |
| Not writable / odd location | Install dir can't be written; macOS App Translocation; running from `/Volumes`; a bare binary without the tarball marker | `support = .needs_manual_update` with a user-facing reason. A permission error during apply also maps to `error.NeedsManualUpdate`. |

The marker file keeps a binary copied into, say, `~/bin` from ever causing the
updater to swap out `~/bin`. The relaunched process gets
`--typebud-updated-from=<old version>`, which `updater.relaunchedFrom(args)`
reads so the app can show an "Updated to X" message.

## Integrating in the app

The app already does all of this (`build.zig`, `src/updates.zig`, `src/main.zig`);
this is the shape of it.

`typebud/build.zig.zon`:

```zig
.dependencies = .{
    .updater = .{ .path = "updater" },
    // .zpui = ...
},
```

`typebud/build.zig` (the app's `-Dupdate-public-key` goes through to the updater):

```zig
const updater_dep = b.dependency("updater", .{ .target = target, .optimize = optimize, .@"public-key" = update_key });
exe.root_module.addImport("updater", updater_dep.module("updater"));
```

App code:

```zig
const updater = @import("updater");

// null: this build has no key. Don't create an Updater; show the releases page instead.
const key = updater.release_key.public_key orelse return;
var u = try updater.Updater.init(gpa, io, .{
    .owner = "plyght",
    .repo = "typebud",
    .current_version = build_options.version,   // e.g. "0.1.0"
    .channel = if (prefs.beta_updates) .beta else .stable,
    .public_key = key,
    .environ_map = init.environ_map,             // proxies, default dirs, $APPIMAGE
});
defer u.deinit();
u.cleanupAfterUpdate();

// Automatic: arm a one-shot timer for u.msUntilNextCheck(), then
if (try u.checkIfDue()) |status| show(status);
// Settings > "Check for updates":
const status = try u.check();     // or u.checkInBackground(ctx, callback)
switch (status) {
    .up_to_date => {},
    .available => |a| switch (a.support) {
        .automatic => {},                      // offer "Update" (a.version, a.notes, a.size)
        .needs_manual_update => |why| {},      // show `why` + link to a.release_url
        .managed_by_package_manager => {},     // "managed by your package manager"
    },
}
try u.download(.{ .ctx = self, .func = onProgress });   // returns at once; callback runs on the download thread
// later: u.downloadState(), u.waitForDownload(), u.cancelDownload()
if (try u.applyAndRelaunch() == .relaunched) quit();     // or: u.applyOnQuit(); and call u.onQuit() at quit
```

Notes:

* `init` takes `io` (Zig 0.17 `std.Io`) as well as the allocator. It returns
  `error.UpdateKeyNotConfigured` for an all-zero or invalid key. A build without
  a key never gets that far: `release_key.public_key` is null and the app
  creates no `Updater` at all.
* `check()` blocks for one or more HTTPS round trips. Call it from
  `checkInBackground` or another short-lived thread if the UI thread must not
  block. `Status` slices stay valid until the next check or `deinit`. Don't run
  a check while a download is running (`error.DownloadInProgress`).
* The `Updater` must not move in memory while `checkInBackground` runs. The
  download state is heap-allocated, so a running download doesn't pin it.
* If the app enforces a single instance, let a process started with
  `--typebud-updated-from=…` wait a moment for the old instance to exit. On
  macOS, `open -n` starts the new copy while the old one is still quitting.
* Default directories: the state file goes in `~/Library/Application Support/typebud`,
  `%LOCALAPPDATA%\typebud`, or `$XDG_STATE_HOME/typebud`. Downloads go in
  `~/Library/Caches/typebud/updates`, `%LOCALAPPDATA%\typebud\updates`, or
  `$XDG_CACHE_HOME/typebud/updates`. Set `state_dir` / `cache_dir` to override.

## Threat model

**Protected against:**

* **Network attackers, including TLS interception and a compromised CDN or
  mirror.** Integrity doesn't depend on TLS. Every installed byte is covered by
  the manifest's SHA-256, and the manifest is covered by the Ed25519 signature.
  TLS (`std.http.Client` with the OS trust store) still provides privacy and
  blocks trivial tampering with the release list.
* **Takeover of the GitHub account or repo without the signing key.** An
  attacker can publish a release but can't produce a valid `manifest.json.sig`,
  so clients refuse it. They can't strip the signature either: releases without
  `manifest.json` + `manifest.json.sig` (including the keyless releases published
  before updates were enabled) are never offered.
* **Tampered or truncated downloads.** Size and SHA-256 are checked after the
  download, and again right before installing. A corrupt partial file is
  thrown away and downloaded again once.
* **Downgrade and replay.** The signed version must be strictly newer than the
  running one, and it must equal the release tag. An old, validly signed
  manifest re-attached to a new tag is rejected.
* **Channel confusion.** The channel is inside the signed manifest. A beta
  build can't be pushed to stable users by toggling GitHub's pre-release flag,
  and a pre-release version number can't ship on stable.
* **Path tricks in archives.** Only fixed artifact names from the manifest are
  used. Only asset URLs under this repo's `releases/download/` path are
  followed. Zip and tar extraction refuses absolute paths and `..` components.
  The archives themselves are covered by the signature, so this is a second
  line of defence. The Linux tarball install dir needs the marker file.
* **Half-installed updates.** Every swap is a short sequence of same-filesystem
  renames, rolled back on failure. Drafts are invisible to clients, and CI
  uploads every asset to a draft before publishing it, so clients never see a
  release with missing assets.

**Not protected against (accepted risks):**

* **Theft of the signing key, or of CI.** Anyone with
  `TYPEBUD_UPDATE_SIGNING_KEY`, or anyone who can make the release workflow run
  with secrets (push a `v*` tag or start `workflow_dispatch`), can ship an
  update. Hardening options: move the secret into a GitHub Environment named
  e.g. `release` with required reviewers and set `environment: release` on the
  `release` job; protect `v*` tags; limit who can write to the repo. There is
  no key rotation in the protocol. A new key means an app build containing the
  new public key, signed with the old key, followed by releases signed with the
  new key.
* **Freeze attacks.** Someone who can block or stall GitHub can keep clients on
  an old version. The manifest carries no expiry.
* **A local attacker who can already write to the install location or the
  user's cache or state directories.** They could replace the app directly.
  (The SHA-256 is still checked again before install.)
* **macOS without Developer ID.** Ad-hoc signed builds work, but Gatekeeper
  shows a warning on the first manual install. TCC permissions (Input
  Monitoring and Accessibility, which a typing companion needs) are tied to the
  ad-hoc code hash, so **users must grant them again after every update**. With
  Developer ID signing, grants persist across updates.
* **No timeouts on stalled connections.** `std.http.Client` has no request
  timeout. A stalled check or download blocks its thread until the OS gives up
  on the connection. Downloads can be cancelled with `cancelDownload()`.

## Enabling updates

Nothing in the repository changes; it's two GitHub settings and a release.

1. On a trusted machine, generate the keypair:

   ```sh
   cd updater && zig build keygen
   ```

   It prints a **public key** and a **private key** (64 hex characters each) and
   writes nothing to disk.

2. Add a repository **variable** `TYPEBUD_UPDATE_PUBLIC_KEY` = the printed public
   key: GitHub > `plyght/typebud` > Settings > Secrets and variables > Actions >
   Variables > New repository variable (or
   `gh variable set TYPEBUD_UPDATE_PUBLIC_KEY --body <public key>`). It isn't
   secret; release builds compile it in with `-Dupdate-public-key`.

3. Add a repository **secret** `TYPEBUD_UPDATE_SIGNING_KEY` = the printed private
   key (Secrets > New repository secret, or `gh secret set TYPEBUD_UPDATE_SIGNING_KEY`,
   which prompts so the key stays out of shell history). Keep an offline backup,
   for example in a password manager, then clear the terminal scrollback. If the
   key is lost, every installed copy must be updated by hand to a build with a
   new public key.

4. Tag a release (below). The workflow sees both settings, builds with the key,
   and signs `manifest.json`. Builds from that release on update themselves.
   Copies of earlier, keyless builds never check, so their users install the
   first keyed release manually once.

The workflow only compiles the key in when **both** are set, so a build that
checks for updates always comes with a signed release. It refuses to sign if the
secret's public half doesn't equal the variable (`typebud-sign
--expect-public-key`), then verifies the result exactly as the app would
(`typebud-update-check verify`). A malformed variable fails the `meta` job.

To try a keyed build locally: `zig build -Dupdate-public-key=<hex>`.

## Optional: macOS Developer ID and notarization

Without these secrets the macOS build is ad-hoc signed and the workflow
continues with a warning. Add all five to get Developer ID signing and
notarization:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | base64 of the exported "Developer ID Application" certificate and private key (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | password of that .p12 |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | app-specific password for that Apple ID (appleid.apple.com → Sign-In and Security) |

The certificate secrets alone give Developer ID signing without notarization.
All five give signing, notarization and stapling.

## Cutting a release

1. Set the version in `build.zig.zon` (`.version`); the tag must match it.
2. Optionally rehearse: **Actions > Release > Run workflow** with `version` (e.g.
   `0.2.0-rc`) and `dry_run` checked. It builds and packages every platform and
   uploads the files as the run's `release-dry-run` artifact; no tag, no release.
3. Tag and push:

   ```sh
   git tag -a v0.2.0 -m "typebud 0.2.0" && git push origin v0.2.0      # stable
   git tag -a v0.3.0-beta.1 -m "typebud 0.3.0-beta.1" && git push origin v0.3.0-beta.1   # beta channel
   ```

   (Or run the workflow with `dry_run` unchecked: it creates the tag at that commit.)
4. The workflow:
   1. checks the version (semver; a `-pre` suffix means the beta channel and a
      GitHub pre-release) and whether updates are configured (see above).
   2. runs the updater tests and cross-compiles them for every target.
   3. fetches zpui at the commit `build.zig` pins (`scripts/fetch-zpui.sh`) and runs
      `zig build package -Doptimize=ReleaseFast -Dversion=<version>` per platform:
      macOS arm64 + x86_64 combined with `lipo` (`-Duniversal=true`)
      (`Typebud.app`, ad-hoc signed, or Developer ID + notarized when those secrets
      exist), Windows x86_64 (portable zip), Linux x86_64 (tarball with the
      `.typebud-install` marker, and an AppImage built with appimagetool 1.9.1 and
      type2-runtime 20251108, both pinned by SHA-256).
   4. with updates configured: writes, signs and verifies `manifest.json`.
   5. creates the release as a draft with every asset (`typebud-macos-universal.zip`,
      `typebud-windows-x86_64.zip`, `typebud-linux-x86_64.tar.gz`,
      `typebud-linux-x86_64.AppImage`, `SHA256SUMS.txt`, and the manifest pair when
      signed), plus, when `scripts/make-dmg.sh` / `scripts/make-installer-windows.ps1`
      succeed, `Typebud-<version>.dmg` and `typebud-setup-<version>-x86_64.exe`
      (first-install downloads, not in the manifest; see docs/RELEASING.md), then
      publishes it. Without updates configured, the notes start with
      "Automatic updates not enabled for this build".
   6. with updates configured: runs `typebud-update-check check --current 0.0.0
      --download` against the live release.

Never move or delete a published tag; fix forward with the next patch version.

## Development

```sh
cd updater
zig build test     # unit tests + mkmanifest → sign → verify round trip (test key)
zig build cross    # compile for x86_64/aarch64 Windows, macOS, Linux
zig build check -- check --current 0.0.0 --public-key <hex>   # live check
zig build keygen   # new keypair (prints only)
```

The unit tests cover:

* semver ordering
* channel filtering of GitHub releases
* manifest parsing and validation
* signatures (good, bad, tampered, wrong key, missing domain prefix, a fixed
  test vector)
* downgrade, replay and tag mismatch
* platform detection and artifact selection
* the mac swap and Windows rename plans as pure functions, and executed on a
  temp dir, including injected failures with rollback
* zip and tar.gz installs from fixture archives
* releases without a signed manifest are skipped

The app's tests (`zig build test` at the repo root) cover the keyless mode (no
`Updater`, no network, the releases page instead), the keyed mode (checks
scheduled on the app's loop) and the settings status strings.

`typebud-update-check check` accepts `--api-base` and `--download-base` to
point it at a local mock server, which is how ETag/304 handling, redirects,
Range resume after a dropped connection, and tamper detection were tested.
