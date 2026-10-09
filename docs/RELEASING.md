# Releasing: installers

The zip/tarball artifacts that the updater consumes (`typebud-macos-universal.zip`,
`typebud-windows-x86_64.zip`, `typebud-linux-*`) stay as they are. The installers below are
**additional** release assets for first-time installs; they are not in `manifest.json` and the
updater never downloads them. Both install to the locations the updater already handles, so an
installed copy updates itself like a zip install does.

| Asset | Script | Built from |
| --- | --- | --- |
| `typebud-setup-<ver>-x86_64.exe` | `scripts/make-installer-windows.ps1` | `<prefix>/typebud/` from `zig build package` (Windows) |
| `Typebud-<ver>.dmg` | `scripts/make-dmg.sh` | `<prefix>/Typebud.app` from `zig build package` (macOS), after signing |

`<ver>` is the semver without the leading `v` (`0.3.0`, `0.3.0-beta.1`). The artwork they use
(`packaging/windows/wizard-*.bmp`, `packaging/macos/dmg-background{,@2x}.png`) is committed;
`scripts/render_installer_art.py` regenerates it from `art/`.

`.github/workflows/installers.yml` builds both on every change under `packaging/` or to these
scripts and exercises them (silent install, upgrade over a running copy, launch, uninstall;
DMG mount + Finder screenshot).

## Windows: `scripts/make-installer-windows.ps1`

```
pwsh scripts/make-installer-windows.ps1 -PackageDir out/pkg/typebud -Version 0.3.0 [-OutDir dist] [-Iscc C:\path\ISCC.exe]
```

* **Input:** the Windows package directory (must contain `typebud.exe`; every file in it is
  installed except `*.pdb`/`*.zip`) and the version.
* **Output:** `dist/typebud-setup-<ver>-x86_64.exe` (path printed last; step output
  `installer` under GitHub Actions).
* **Runner tools:** `windows-latest`, Inno Setup 6 (`choco install innosetup -y --no-progress`).
* **What it installs:** per user, no UAC prompt, into `%LOCALAPPDATA%\Programs\typebud`
  (the updater's Windows install location); Start Menu shortcut; optional desktop shortcut;
  optional "Launch typebud when I sign in" (HKCU `...\CurrentVersion\Run`, value `typebud` =
  `"<dir>\typebud.exe"`, the same value the app's Launch at Login toggle writes). Upgrades
  replace the existing install in place (fixed AppId `{90046696-87F8-4838-81E6-43CEE02FA39E}`)
  and close a running typebud first. The uninstaller closes typebud, removes the Run value and
  the updater's `%LOCALAPPDATA%\typebud`, and keeps settings in `%APPDATA%\typebud` unless the
  user says yes to the prompt (or passes `/REMOVESETTINGS`).
* **Silent use:** `typebud-setup-<ver>-x86_64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART [/TASKS="desktopicon,startup"]`.
* **Signing:** if release.yml gains an Authenticode certificate, sign `typebud.exe` before
  running the script and the setup .exe after it (`signtool sign /fd sha256 /tr <tsa> /td sha256 ...`).

## macOS: `scripts/make-dmg.sh`

```
scripts/make-dmg.sh out/pkg/Typebud.app 0.3.0 [dist]
```

* **Input:** the signed `Typebud.app` (run it **after** the codesign step, so the app inside
  the DMG carries the same signature as the zip) and the version.
* **Output:** `dist/Typebud-<ver>.dmg` (step output `dmg`). ULFO (LZFSE) by default;
  `DMG_FORMAT=UDZO` for zlib.
* **Runner tools:** `macos-15` (or newer) with its logged-in GUI session; only built-in tools
  (`hdiutil`, `osascript`/Finder, `tiffutil`, `ditto`, `SetFile` or `xattr`). No Homebrew.
  Finder must be scriptable by the runner (it is on GitHub's macOS images).
* **Notarization:** when the Developer ID secrets are present, notarize and staple the DMG
  too: `xcrun notarytool submit dist/Typebud-<ver>.dmg --wait ...` then
  `xcrun stapler staple dist/Typebud-<ver>.dmg`. Without them the app is ad-hoc signed and the
  background tells users to right-click Typebud and choose Open on first launch.

## Snippet for release.yml

Windows job, after `zig build package ... --prefix out/pkg` (and any signing of the exe):

```yaml
      - name: Install Inno Setup
        run: choco install innosetup -y --no-progress
      - name: Windows installer
        id: installer
        run: ./scripts/make-installer-windows.ps1 -PackageDir out/pkg/typebud -Version $env:VERSION -OutDir installers
      # upload installers/typebud-setup-${{ env.VERSION }}-x86_64.exe with the other release assets
```

macOS job, after the codesign (and before or after notarizing the zip):

```yaml
      - name: Disk image
        id: dmg
        run: scripts/make-dmg.sh out/pkg/Typebud.app "$VERSION" installers
      # optional, with Developer ID secrets:
      #   xcrun notarytool submit "installers/Typebud-$VERSION.dmg" --wait --apple-id ... --team-id ... --password ...
      #   xcrun stapler staple "installers/Typebud-$VERSION.dmg"
      # upload installers/Typebud-${{ env.VERSION }}.dmg with the other release assets
```

Both files go on the GitHub release next to the zips, but they must **not** reach
`typebud-mkmanifest`: it rejects any file that is not a known updater artifact name, and the
publish job currently passes it the glob `dist/typebud-*`, which would match
`typebud-setup-<ver>-x86_64.exe`. Keep the installers out of `dist/` until the manifest is
written (the snippets use `installers/`), or pass mkmanifest the four updater artifact names
explicitly, then attach `installers/*` to the release with the rest.
