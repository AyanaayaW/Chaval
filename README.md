# Chaval

**An all-in-one ricing helper for macOS.** Dock, top bar, launcher, themes and an animated tiling window manager,
all in one native app.

Ricing a Linux desktop means making it your own: a tiling window manager, a custom bar, a matching theme across
everything. On macOS that usually takes half a dozen separate tools (yabai, skhd, SketchyBar, JankyBorders, Raycast,
…) wired together by hand. Chaval does all of it in one app, aiming for the feel of Hyprland / Omarchy, without
turning off System Integrity Protection or touching the OS. It's written in Swift and AppKit with no third-party
dependencies.

### Why "Chaval"?
*Chaval* (चावल) is Hindi for **rice**, because it helps you rice macOS. 🍚

> [!WARNING]
> **Chaval is vibecoded.** Almost all of the code was written by an AI (Claude) while I described what I wanted,
> tested it on my own Mac, and said what was wrong. I'm not a professional macOS developer and haven't reviewed
> every line myself. It works well enough for me to use every day, but treat it as a **beta**: expect rough edges and
> bugs, read the code before you trust it with anything important, and keep in mind it uses private macOS APIs that a
> future update could break.

## What's in it

### Dock
- Replaces the macOS Dock: pinned apps, running apps, recents, folders/stacks, Trash, minimized windows, badges and
  magnification. Or switch to **taskbar mode**: one tile per open window.
- Widgets can sit in the dock: clock, date, desktops, Now Playing, battery, CPU and memory.
- Place it on any edge. Pick one display, or let it follow your pointer: push against the bottom of another screen
  and it moves there.
- Optional borders and accent colours that follow your theme.
- The macOS Dock is hidden, not killed (it also runs Mission Control and Spaces). Your original Dock settings are
  restored when you quit Chaval.

### Top bar
- A themeable bar drawn over the menu bar. Its left, centre and right sections can hold app menus, the active app,
  workspaces, menu bar icons, Wi-Fi, Bluetooth, volume, brightness, keyboard layout, battery, CPU, memory, Now Playing,
  the clock, text, or a shell command's output.
- Hover pop-outs for Wi-Fi, Bluetooth, volume and more. Scroll on the bar to change desktops, volume or brightness.
- Your existing menu bar icons stay clickable, and are recoloured to match the theme when Screen Recording is
  allowed.

### Tiling window manager
- Layouts: **main + stack**, **dwindle**, **grid** and **accordion**, per display.
- Windows **glide** into place using Omarchy's animation curve. On macOS, an outside app can't animate another app's
  windows, so Chaval briefly draws snapshots of the windows in motion and hands over to the real windows when they
  land.
- Keyboard focus, swap, resize, float, zoom, more/fewer main windows, move to another desktop or monitor, and
  ⌥-drag to rearrange.
- **⌘Return** opens a new Ghostty window directly on its tile.
- Window borders drawn by Chaval itself. Optional focus-follows-mouse.

### Launcher and switcher
- **⌘Space** launcher: apps, files, emoji, a calculator, web search, themes, wallpapers and Chaval's own commands.
  It takes ⌘Space over from Spotlight while running and hands it back when you quit.
- A **⌘Tab** switcher that shows this desktop's windows, in your theme.

### Dashboard and themes
- A panel that slides down from the top: Control Center, Now Playing, system stats, weather, wallpapers, quick
  launch, notes, a shortcuts list, a dotfile/tool manager and themes.
- 17 theme families: Vesper, Everforest, Catppuccin, Rosé Pine, Tokyo Night, Nord, Gruvbox, Monokai, Dracula, One
  Dark, Solarized, Kanagawa, Ayu, GitHub, Night Owl, Nightfox and Oxocarbon. A theme restyles the bar, dock and
  dashboard, and can also recolour **Ghostty**, **tmux**, **cava** and **fastfetch** (see [Files it touches](#files-it-touches)).
- Keep-awake (like Amphetamine) is built in.

## Install

Requires **macOS 14 or later**. I've only tested it on an M4 MacBook Air running macOS 27 with an external monitor.

**From the release:** download the zip from [Releases](../../releases), unzip it and move `Chaval.app` to
Applications. It isn't notarized by Apple, so the first time you have to **right-click → Open**.

**From source** (needs Xcode or the Swift toolchain):

```sh
git clone https://github.com/AyanaayaW/Chaval.git
cd Chaval
make app    # build and install to ~/Applications/Chaval.app
make test   # run the self-checks
```

### Permissions

Chaval asks for these on first launch. Turn them on in **System Settings → Privacy & Security**, then quit and
reopen Chaval.

| Permission | What it's for |
|---|---|
| **Accessibility** | Tiling, window lists, focus, desktop shortcuts, menu bar icons. Most features need it. |
| **Screen Recording** | Smooth window animations, and recolouring menu bar icons. Without it, windows jump into place. |
| Location *(optional)* | Showing Wi-Fi network names (macOS hides them otherwise). |
| Bluetooth *(optional)* | The Bluetooth device list. |

Builds signed ad-hoc (the default from source) lose the Accessibility permission each time you rebuild. You have to
switch it off and on again in System Settings.

### Desktop shortcuts
⌥1–9 work by sending macOS's own "Switch to Desktop N" shortcuts. Turn those on in **System Settings → Keyboard →
Keyboard Shortcuts → Mission Control** (⌃1, ⌃2, …), and create the desktops in Mission Control first.

## Default shortcuts

Every shortcut can be changed in Settings → Keys (written skhd-style, e.g. `alt + shift - h`).

| Keys | Action |
|---|---|
| ⌥ H / J / K / L | Focus left / down / up / right |
| ⌥⇧ H / J / K / L | Swap window left / down / up / right |
| ⌥⌃ H / L | Main window narrower / wider |
| ⌥⌃ J / K | Window taller / shorter |
| ⌥⌃ 0 | Reset sizes |
| ⌥⇧ Return | Make main window |
| ⌥ [ / ] | Focus previous / next window |
| ⌥ F | Zoom (fill the screen) |
| ⌥⇧ F | Native full screen |
| ⌥ T | Float / tile the window |
| ⌥ Q | Close window |
| ⌥⇧ T | Tiling on / off |
| ⌥⇧ R | Re-tile now |
| ⌥⇧ Space | Next layout |
| ⌥⇧ = / − | More / fewer main windows |
| ⌥ 1 … 0 | Go to desktop 1–10 |
| ⌥⇧ 1 … 0 | Move window to desktop 1–10 |
| ⌥⌃ ← / → | Previous / next desktop |
| ⌥⇧ , / . | Move window to previous / next monitor |
| ⌘ Return | New Ghostty window on its tile |
| ⌘ Space | Launcher |
| ⌘ Tab | Window switcher |
| ⌥ D | Dashboard |
| ⌥ , | Settings |
| ⌥⇧ W | Next wallpaper |
| ⌃⌥ D | Hide / show the dock |
| ⌥⇧ B | Hide / show the top bar |

Right-click the dock for quick options. Everything else is in Settings (also a page in the dashboard).

## Files it touches

Chaval stays out of system files. Outside its own settings (`dev.chaval.dock`), it only writes these, and only when
you use the matching feature:

- **macOS Dock settings:** sets the Dock to auto-hide with a long delay, and restores the originals on quit.
  If Chaval crashes or is force-killed, reopen and quit it properly to get your Dock back.
- **Ghostty:** `~/.config/ghostty/chaval-theme` and `chaval-window`, plus one `config-file = ?…` line per file
  added to your config. The original is backed up to `config.before-chaval`.
- **tmux, cava, fastfetch:** theme colours, each with a `.before-chaval` backup of the original.
- **Keep awake with the lid closed** (only if you turn it on): asks for your password once to add a sudoers rule
  that allows exactly `pmset -a disablesleep 1` and `0`.

## Known limits

macOS doesn't let third-party apps do everything the system Dock or a Linux compositor can:

- There's no **live** window animation. The glide uses snapshots, so the content of a moving window is frozen for
  a moment.
- Switching desktops uses macOS's own slide. It can't be made instant or replaced without disabling SIP.
- Some apps have minimum sizes or snap to a grid (terminals), so their tiles may not fit exactly.
- The dock has no download progress bars, no attention bounce and no app-provided dock menu items.
- Private SkyLight APIs are used for reserving screen space, desktops and focus. A macOS update can break them.

## Credits

- Window animation ideas from [Dinky](https://github.com/mikker/Dinky) (MIT).
- The animation curve and feel are modelled on [Omarchy](https://omarchy.org) / Hyprland.
- Desktop pinning tricks learned from SketchyBar, and default keys from skhd + yabai.
- Code written with [Claude Code](https://claude.com/claude-code).
