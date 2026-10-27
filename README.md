# Chaval

A native Dock replacement for macOS (Swift + AppKit, no dependencies).

```
make run    # build, install to ~/Applications/Chaval.app, launch (replaces a running copy)
make test   # magnification layout self-check
```

Chaval hides the system Dock (auto-hide with a 1000 s delay) rather than killing it, because the
Dock process also runs Mission Control, Spaces and the app switcher. Your original Dock settings are
restored when you quit Chaval (not on logout/restart).

- **Accessibility** permission enables window lists, minimized windows, scroll-to-cycle and badges.
  Builds are ad-hoc signed, so each rebuild needs the permission re-toggled in System Settings.
- **⌃⌥D** toggles hiding. (⌥⌘D belongs to the system Dock and would un-hide it.)
- Right-click the dock background for quick options; everything else is in Chaval Settings.

Known limits: zoomed windows can slide under an always-visible dock (only the system Dock can
reserve screen space); no download progress bars, no attention bounce and no app-provided dock-menu
items (none of these are exposed to third-party apps).

## Top bar

A themeable bar drawn over the menu bar (Settings → Top Bar). Windows stop below it because the real menu bar is still
there underneath. Its sections sit left, center or right and can hold app menus, the active app, every app's menu bar
icon, Control Center and system icons, the clock, date, battery, CPU, memory, Now Playing, text, or a shell command's
output. Menu bar icons are read through Accessibility (`Chaval --dump-extras FILE` lists what it sees), and clicking one
appear at their real spots. Hovering one makes the bar click-through, so the real icon takes the click (hold ⌥ to use
the bar's own right-click menu there). With Screen Recording allowed, each icon's real shape is copied off the screen and
drawn in the theme colour. Pushing the pointer to the top centre, the dashboard button or the bar's clock opens a panel that slides down. Its sections are Control Center, Now Playing, System, Wallpapers, Quick Launch, Notes, Custom Manager (dotfile tools and your own commands) and Themes. Control Center has: clock, calendar, Now Playing,
volume, brightness, light/dark mode, keep awake, stats, bar themes and power. `Chaval --render-bar FILE.png` draws the
bar and the panel to images.

## Themes

The dashboard's Themes page (or Settings → Top Bar → Theme) lists Vesper, Everforest, Catppuccin, Rosé Pine,
Tokyo Night, Nord, Gruvbox, Monokai, Dracula, One Dark, Solarized, Kanagawa, Ayu, GitHub, Night Owl, Nightfox and
Oxocarbon. A theme restyles the top bar, the panel and the dock. It writes the colours to `~/.config/ghostty/chaval-theme`
(the config gets one `config-file = ?chaval-theme` line, and the original is backed up to `config.before-chaval`) and reloads
Ghostty. It also recolours a running `borders`.
