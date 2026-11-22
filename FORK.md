# Phi+ (unofficial fork)

Phi+ is a personal, **unofficial** fork of [Phi Browser](https://github.com/phibrowser/phibrowser-mac)
for macOS. It is not made, endorsed or supported by Phinomenon Inc. It builds the
open-source client (`PhiBrowser-OpenSource` scheme) with its own name and bundle id
(`com.bengutteridge.phiplus`), so it runs beside an installed Phi with its own data.

The client source is Apache 2.0, like upstream ([LICENSE](LICENSE)). Phi Browser and its
logo are Phinomenon's trademarks; this licence grants no trademark rights.

## What Phi+ adds

All on the `phi-plus` branch, on top of Phi 2.18.0:

- Space switcher: dot style and a bottom-center placement (Settings → Spaces)
- Omnibox in the Space's color; theme editor with the classic 2.12 presets, a
  saturation slider and a per-Space transparency slider
- A native empty state instead of a new tab after closing the last tab
- A floating history panel (⌘Y) over the page, with full-history search
- Settings to keep pinned tabs and tabs in closed folders out of Ctrl-Tab and ⌘1–⌘8
- A floating address bar over any app (⌥Space by default)
- Live hover cards for Gmail and TickTick pinned tabs; the Gmail card can show
  Thunderbird's Unified Inbox natively, and the TickTick card a native task
  list over TickTick's Open API (with a personal API token)
- Bitwarden desktop bridge registration, so the extension can unlock with Touch ID
- Circular download icon and progress ring
- A picture-in-picture button on videos when you hover them, embedded players included (Settings → General)
- Autoplay control: pages in tabs opened from links, unloaded tabs and background loads start paused,
  with per-site rules (Settings → General → Autoplay, the extensions menu, and the address bar button)
- Copy Link and Autoplay address bar buttons, toggled from the sidebar's right-click menu
- A Picture in Picture shortcut (⌃⌘P by default)
- The last session restores after a crash or a forced quit

## Build

Requirements: Apple silicon, Xcode 26 or later.

```sh
./scripts/download_phi_framework.sh --version 2.18.0
xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser-OpenSource \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-OpenSource
```

The app is at `build/DerivedData-OpenSource/Build/Products/OpenSource/Phi.app` and
shows as Phi+. A self-built copy has no Phi account, Phi Cloud AI, Phi Sync or updates.

## Phi Browser Framework

Built with Phi Browser Framework, part of the Phi Browser project. Copyright Phinomenon Inc.
Used under the Phi Browser Framework Binary License.
https://github.com/phibrowser/phibrowser-framework

The framework is downloaded by `scripts/download_phi_framework.sh` and is never committed
here. It may be redistributed only unmodified, and must not be modified or reverse engineered.
