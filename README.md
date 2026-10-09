<div align="center">

<img src="docs/assets/hero.png" alt="typebud's four friends typing: a capybara, a cat, a penguin and a shiba" width="760">

# typebud

A cozy little animal sits in the corner of your screen behind its own tiny keyboard and taps away whenever you type, anywhere on your computer. It runs on macOS, Windows and Linux.

[**Download**](https://github.com/plyght/typebud/releases/latest) · [Features](#features) · [Build from source](#build-from-source) · [Privacy](#privacy)

</div>

---

## Features

- You can pick from four hand-drawn friends, a cat, a capybara, a penguin and a shiba, and each one has its own personality.
- Your buddy taps with whichever paw matches the side of the keyboard you're using, gets excited when you type quickly, and curls up for a nap once you've stopped for a while.
- You can dress it up with headphones that float music notes while you type, or with a beanie, a party hat, a bow or glasses, and it can hold a coffee, a boba or a book to sip between sentences.
- The keyboard and gear come in dark, bright and pink, and you can add a plant, a lamp or a mug to the desk, or hide the keyboard altogether.
- If you like the sound of typing, there are nine mechanical keyboard sound packs built in, from creamy linears to a buckling spring, and you can import any Mechvibes, MechvibesDX or Thock pack too. Sounds mute themselves automatically while other audio is playing or you're on a call.
- It stays out of your way, because clicks pass straight through everything except the pet itself. You can drag it to any corner of any display, resize it with its grip, and choose to show it only in certain apps or to hide it in others.
- The settings window feels at home on every system, with Liquid Glass on macOS 26 and later, libadwaita or Breeze styling on Linux, and Mica on Windows, and there's a menu bar or tray icon for quick access.
- It's very light on your computer, because it draws nothing while nothing is happening and sits at roughly zero CPU when idle.

<div align="center">
<img src="docs/assets/settings-macos.png" alt="typebud settings on macOS" width="560">
</div>

## Install

You can grab the latest build from [**Releases**](https://github.com/plyght/typebud/releases/latest).

| Platform | Download | Notes |
|---|---|---|
| macOS 12+ (Intel & Apple Silicon) | `Typebud-<version>.dmg` | Open the disk image and drag typebud into Applications. Because the build isn't notarized yet, right-click typebud and choose **Open** the first time you launch it. |
| Windows 10/11 | `typebud-setup-<version>-x86_64.exe` | The installer sets typebud up just for your account, so it doesn't need admin rights, and a portable `.zip` is available as well. |
| Linux (x86_64) | `typebud-linux-x86_64.AppImage` | Make the file executable with `chmod +x` and run it, or use the `.tar.gz` if you prefer. |

On **macOS**, typebud notices typing without asking for any permission. Turn on **Precise Typing Detection** in Settings if you'd like the paws to follow exactly which side of the keyboard you hit (macOS will ask for Input Monitoring).

On **Linux under Wayland**, apps can't see system-wide key presses, so typebud reads your keyboard devices directly, which works once you add yourself to the `input` group with `sudo usermod -aG input $USER` and log back in. On X11 it works straight away.

## Privacy

typebud only ever learns *that* a key was pressed and roughly where it sits on the keyboard, which is all it needs to pick a paw, so it never sees or stores what you actually type. Everything runs offline, and the only time it reaches the network is the optional update check, which reads this repository's GitHub releases.

## Build from source

You'll need [Zig 0.17](https://ziglang.org/download/), and typebud is built on [zpui](https://github.com/plyght/zpui), a Zig port of Zed's GPU UI framework.

```sh
git clone https://github.com/plyght/typebud && cd typebud
scripts/fetch-zpui.sh          # checks out the pinned zpui into ./zpui
zig build run                  # build and launch
zig build test                 # unit tests
zig build package              # Typebud.app / portable zip / tarball + AppDir
```

On Linux you'll also need the Vulkan, Wayland, X11, FreeType, HarfBuzz and fontconfig development packages. The exact list is in [`.github/workflows/app.yml`](.github/workflows/app.yml).

## Project layout

```
src/        the app: pet window, animation, sounds, settings, tray
art/        the animals, drawn as layered SVGs (see art/SPEC.md and art/STYLE.md)
sounds/     bundled keyboard sound packs and their licenses
updater/    signed over-the-air updates from GitHub Releases
packaging/  icons, the Windows installer and the macOS disk image
scripts/    art previews, sound pack importer, installer and release helpers
```

Working on the art? `python3 scripts/render_art.py <animal>` renders every frame in all three vibes to `art/<animal>/preview/`.

## Releases & updates

Releases are built by GitHub Actions when a `v*` tag is pushed. Automatic updates turn on as soon as an update-signing key is set up; until then each release is a normal download. See [`docs/RELEASING.md`](docs/RELEASING.md) and [`docs/UPDATES.md`](docs/UPDATES.md).

## Credits

Sound packs come from [kbsim](https://github.com/tplai/kbsim) and [Keyboard Sounds Pro](https://github.com/keyboard-sounds/keyboardsounds-pro) (MIT), with full attributions in [`sounds/LICENSES.md`](sounds/LICENSES.md) and in the app under **Settings → Credits**. Keycap legends use [Nunito](https://github.com/googlefonts/nunito) (SIL OFL 1.1). Inspired by the lovely [Typibara](https://www.typibara.com/).

<div align="center">
<sub>Made with love (and paws) by <a href="https://github.com/plyght">plyght</a>.</sub>
</div>
