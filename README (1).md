# 🎮 GameDock

A sleek, modern game launcher for Windows 11 — all your games in one place, one click away.

Wide bubble-style buttons, real game icons, dark glassmorphic UI. Works with **Steam**, **Xbox / Game Pass**, and any installed or downloaded game.

![Platform](https://img.shields.io/badge/platform-Windows%2011-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## ✨ Features

- 💊 **Wide bubble UI** — each game is a pill-shaped bubble with its own accent color
- 🖼️ **Real game icons** — extracted straight from the game's `.exe`
- ➕ **Add anything** — `.exe` files, shortcuts (`.lnk`), Steam/Xbox shortcuts (`.url`)
- 💾 **Persistent library** — your games are saved and survive restarts
- 🚀 **Native Windows app** — compiles to a real `GameDock.exe` on your machine, no runtime dependencies, no background services
- 🔒 **Fully transparent** — one readable script builds everything locally; nothing is downloaded

## 📦 Install

### Option 1 — One-liner (easiest)

Open **PowerShell** (Win key → type `powershell`) and paste:

```powershell
irm https://raw.githubusercontent.com/Lty7o3/gamedock-v1/main/install.ps1 | iex
```

### Option 2 — Manual

1. Download [`install.ps1`](install.ps1)
2. Open PowerShell and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

Either way: in about 10 seconds, **GameDock.exe** appears on your Desktop and opens itself. Done!

> **Note:** the first time you run the app, Windows SmartScreen may show *"Windows protected your PC"* — click **More info → Run anyway**. This happens because the exe is freshly built on your own PC and unsigned. It only asks once.

## 🕹️ Usage

| Action | How |
|---|---|
| Add a game | Click **+ Add a game**, pick the game's `.exe` or shortcut, name it |
| Launch a game | Click its bubble |
| Remove a game | Click the **✕** on its bubble |
| Move the window | Drag anywhere on the card |

New to this? Read the friendly **[Beginner's Guide](docs/BEGINNER-GUIDE.md)** — it covers adding games from Steam, Xbox / Game Pass, and regular downloads, plus pinning GameDock to your taskbar.

## ⚙️ How it works

`install.ps1` contains the complete app source code (C# / WPF) embedded inside it. When you run it, it:

1. Writes the source to `%LOCALAPPDATA%\GameDock`
2. Draws the app icon and packs it into a multi-size `.ico`
3. Compiles a native `GameDock.exe` using `csc.exe` — the C# compiler **built into every Windows** (.NET Framework 4.x)
4. Copies the exe to your Desktop and launches it

No downloads, no package managers, no admin rights, no telemetry. Your game library is stored as a plain text file at `%APPDATA%\GameDock\games.txt`.

## 🗑️ Uninstall

Delete these two folders and the desktop exe — that's the entire footprint:

```
%LOCALAPPDATA%\GameDock
%APPDATA%\GameDock
```

## 🤝 Contributing

Issues and pull requests welcome! The full app source lives inside [`install.ps1`](install.ps1) (the `$csSource` here-string).

## 📄 License

[MIT](LICENSE) — do whatever you want with it.
