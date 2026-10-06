# SysMeter

A tiny macOS menu bar app that shows your CPU and RAM usage as live, color-coded progress bars.

```
CPU ▰▱▱▱ 16%   RAM ▰▰▰▰▰▱▱ 72%
```

🟢 under 60%  ·  🟠 60–85%  ·  🔴 over 85%

## Features

- CPU and RAM progress bars right in the menu bar, updated every second
- Click for details:
  - **CPU:** total usage, the User / System / Idle split and a bar for each core
  - **Memory:** used, total and available RAM, plus App memory, Wired, Compressed, Cached files and Swap
  - **Memory pressure** (Normal / Warning / Critical): the best sign of whether you need more RAM
- Shortcut to open Activity Monitor
- Open at Login option
- Native Swift, a single file, no dependencies, very low CPU use

## Install

1. Download **SysMeter.zip** from the [latest release](../../releases/latest).
2. Unzip it and drag **SysMeter.app** into your **Applications** folder.
3. Open it. macOS will warn that the app is from an unidentified developer, because it isn't notarized by Apple. To open it anyway:
   - Right-click the app → **Open** → **Open**, or
   - go to **System Settings → Privacy & Security** and click **Open Anyway**.

It needs no permissions. Works on Apple Silicon and Intel Macs running macOS 13 (Ventura) or later.

## Why is my RAM almost full?

That's normal. macOS keeps RAM busy with caches on purpose, because unused RAM is wasted RAM. Look at **Memory pressure** instead: if it's 🟢 Normal, your Mac has enough memory.

## Build from source

```sh
git clone https://github.com/MrSagarRB/SysMeter.git
cd SysMeter
./build.sh
open SysMeter.app
```

You need the Xcode Command Line Tools (`xcode-select --install`).

## License

MIT
