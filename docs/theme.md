# Theme

## What it is

Every colour of the shell comes from one theme: a pair of palettes, light and dark, in one JSON file. A button in the left island
switches light and dark, and its popup shows every theme as two little desktops to pick from; with `themectl` the same switch also
recolours the rest of the desktop (kitty, the window borders, GTK, btop, the wallpaper and more), so everything changes together.

## Where it lives

- **The theme button**: the `theme` id in the left island (`modules/shell/ThemeBarButton.qml`): a swatch book, a fan of colour
  cards on one rivet -- the filled swatch (`md-palette_swatch` U+F08B5) in light mode and in dark alike.
  While a switch runs its ink leans towards the accent colour; after a switch that failed it leans towards the warning colour
  for a few seconds. Under the pointer it takes its hover hue (`theme.hover` in `modules/common/glyphs/BarHues.js`: the theme's
  yellow first, the one hue nothing else in the left island wears).
- **Its flourish**: when the pointer comes onto the icon (and now and then by itself, the OLED care's random turns) the swatch book
  is flipped: it leans back, snaps shut, turns once in the air, and as the card in front lands the cards behind fan out from under
  it, a little too wide, and settle. 0.8 s. The swatch stays the filled swatch through every frame (its rivet a hole, a gap between
  two cards) and it holds still while the theme crossfades, so a right click while the book is in the air freezes it for the fade.
- **The theme popup** (`modules/theme/ThemePopup.qml`): one row per theme, its light card and its dark card joined by flowing
  strands, the theme's name above them (a name is shown with its dashes as spaces: `night-owl` reads "night owl", here, in the
  theme OSD and in themectl's notifications; files, keys and commands keep the dashes). Each card is a mini desktop in that theme and mode: the islands, the slim bars, a terminal in
  the theme's colours and a window over it.
- No keyboard shortcut and no IPC target of its own. From a terminal: `tools/theme/themectl toggle`.

## What you can do

- **Right click the button**: light <-> dark, at once, with no popup.
- **Left click the button**: the theme popup opens. The cards float and tilt towards the pointer. A click on a card applies that
  theme in that mode; the popup stays open while the switch runs under it, so the result can be seen and another card picked.
- **Keys in the popup**: once the pointer has moved onto the popup, the arrow keys move between cards and Enter applies one. Escape
  closes it like any popup.
- **Watch it switch**: the whole shell crossfades to the new palette in 420 ms on one clock. Parts that keep moving through the fade
  (the player's vinyl, silicon's board, the theme cards) recolour live instead of being frozen in the fade's picture.
- **The curtain** (optional, off by default): a picture of every screen is laid over the desktop, the switch runs behind it, and the
  picture is taken away when the desktop has settled, so windows, bars and apps change in the same moment. The picture is uncovered
  from the pointer (`radial`), travels across the screen (`peel`), opens in strips (`louvres`), or the next style each time (`cycle`).
  The curtain takes no input: clicks and keys reach the windows under it. Anything that would make the picture a lie (a workspace
  switch, a window opening, closing or moving, an output plugged, the session locking, another click on the button) ends it at once.
  It is never used while the session is locked. With `curtainLive` the shell stays live behind the picture and changes with the
  windows, by the same line.
- **The windows nobody is looking at**: a window on another workspace, in the special workspace or behind another tab of its group
  would keep its old colours and flash them for a frame or two when you next go there (Hyprland suspends a hidden window; kitty and Qt
  draw nothing then). So while the curtain holds its picture, every hidden workspace and every hidden tab is shown for a few frames
  under it and everything is put back: the workspaces, the tabs, the focus, the pointer. It adds no time in normal use (the curtain
  waits 400 ms for the apps anyway; a run with many workspaces and deep groups makes that wait as long as it needs). What the bar
  shows of the focus (the workspace ball, the window title) holds still meanwhile. Left alone: a monitor showing a fullscreen
  window and a hidden workspace that holds one. Change a workspace yourself during the run and it stops at once, nothing is
  pulled back. Only with the curtain; `"curtainRepaint": false` turns it off.
  How long a window stays on show is its app's: `curtainRepaintClassFrames` gives a window class its frames (on a 120 Hz panel
  kitty needs 2, VS Code about 16, zen about 24), every other window takes `curtainRepaintFrames`, and a step that shows several
  windows stays as long as the one that needs most. VS Code also notices its settings file late (some 0.4 s after it changed), so
  `themectl` writes VS Code's setting second of all.
  To WATCH it: `"curtainRepaintDebug": true` makes a switch run without the curtain and the repaint slowed to 0.9 s a step, each
  step named in a notice at the top of the screen with the windows it shows and the frames a real run gives it
  (`2/7  tab 3: com.microsoft.VSCode  16 frames`). `python3 tools/theme/hidden_repaint.py plan --frames 2 --class zen=24` prints
  the same for the session as it is, changing nothing.
- **Prompts already printed** follow the switch too: the starship powerline prints palette slots (53-56, 89-92) that kitty's theme
  file colours, so kitty and yazi's header recolour what is on screen. In a terminal that cannot theme slots 16-255 (VS Code's) the
  prompt shows that terminal's own colours.

## What it shows and where the data comes from

- **The themes**: `~/.config/theme/themes/<name>.json` once `themectl install` has copied them there; until then the repo's
  `themes/<name>.json`. Eight are shipped:

  | Theme | Light | Dark | btop (light / dark) |
  |---|---|---|---|
  | `eva` | eva light | eva dark | stock flat-remix-light / flat-remix |
  | `everbox` | Everforest | Gruvbox | stock everforest-light-medium / gruvbox_dark_v2 |
  | `catppuccin` | Latte | Macchiato | custom / custom |
  | `monokai` | Monokai Pro Light | Monokai Pro | custom / custom (`monokai-light`, `monokai-dark`: apart from btop's own `monokai`) |
  | `night-owl` | Night Owl Light (Light Owl) | Night Owl | custom / stock night-owl |
  | `paper` | Paper (btop's, vim-paper's palette) | Paper dark, made here | stock paper / custom |
  | `riso` | risograph inks on white stock | the same inks on burgundy stock | custom / custom |
  | `tokyo-night` | Tokyo Night Light | Tokyo Night Storm | custom / stock tokyo-storm |

  `monokai` was `monokai-pro` until 2026-11-08: `themectl install` carries a home over (RENAMES in themectl: the old copy goes into the
  backup -- or, when you edited it, becomes `monokai.json` --, `state.json`, the `shell.jsonc` wallpaper key, the wallpaper bag and the
  btop / fastfetch files follow; no ghost `monokai-pro` stays behind, not even after a `restore`). `themectl doctor` says when one waits.
  Each pair's `note` says where its colours come from and where the shell's rules made it depart from its source. A theme file has a `light` and a `dark`
  block of colour tokens (and an `assets` block for the desktop's programs: GTK theme, icon theme, btop theme, VS Code theme,
  fastfetch logo). A token may be a hex colour or a recipe on another token (`"@accent lighten 0.1"`). A token a theme leaves out
  falls back to the shell's built-in value (the eva light palette in `modules/common/theme/Theme.qml`), so a half-written theme still
  draws. `gtkTheme`, `iconTheme` and `vscodeTheme` may be a list, best installed first ("Theme packages", below).
- **Which theme is in force**: `~/.config/theme/state.json` (`{"theme": "eva", "mode": "light"}`). The shell follows this file: a
  switch from anywhere (the button, `themectl`, a script) lands there first and the shell crossfades as it changes.
- **The popup's list** is read again on every open, so a theme file added while the shell runs is a card the next time.
- **themectl** (`tools/theme/themectl`) turns the theme into each program's own files and settings. Its targets are listed in
  `tools/theme/targets.json`, each with a template in `tools/theme/templates/`: the shell's state file, the wallpaper (hyprpaper),
  yazi's view of the wallpaper list (`yazi`, below), nwg-look's stored settings (`nwg-look`, below), Evince's inverted colours
  (`evince`: dark inverts; the default, every recent document's own copy and every open window, carried out by a background worker so
  the switch does not wait for it; real-program gate `tools/dev/themectl_evince_env_probe.sh`),
  Hyprland's borders, group tabs and shadow (a generated `theme.lua`), kitty, btop, starship, VS Code, GTK (gsettings and the GTK 3 / 4
  `settings.ini`), libadwaita's colours and accent (`libadwaita`, `gnome-accent`, below), fastfetch's logo, hyprlock's colours, and a mode file for the Windows VM (`tools/theme/windows/`). Every target
  prints `ok` or `FAIL <reason>`; one notification reports a run that failed.
- **btop and fastfetch**: btop's `current.theme` and fastfetch's `archlogo_current.png` are links to the mode's theme and logo. Where
  btop ships a theme that matches, the link names it in `/usr/share/btop/themes/`; otherwise the theme file names a custom btop theme
  in `tools/theme/btop/`, and the logos of the newer pairs (the Arch line logo in the mode's accent) are in `tools/theme/fastfetch/`.
  themectl copies such a file into the app's own directory (`~/.config/btop/themes/`, `~/.config/fastfetch/`) the first time it is
  used, and `themectl install` refreshes them; a copy you edited there (newer than the repo's) is kept.
- **Group tabs** (`tools/hypr-group-tabs`): a group's active tab is drawn inside its border, from the border colour to the theme's
  `hyprGroupTab` (the warn colour unless a theme says otherwise); a locked group's tab takes `hyprBorderLocked`, chosen in every theme
  to stand apart from both the border and the tab. A locked group's border is the plain border.

`themectl` commands: `apply`, `set <theme> [mode]`, `toggle`, `next`, `diff`, `list`, `doctor` (is the machine ready: the include
lines each app's config needs, and per pair which preferred theme package is missing), `packages` (the install list for those),
`install` (copy the repo's themes to `~/.config/theme/themes`, carry a renamed pair over, set yazi up for the wallpapers once), `migrate`
(make the one-time edits `doctor` asks for, keeping the originals), `restore` (put back the originals it kept), `resolve`, and
`wallpaper set <image>` / `wallpaper remove <image>` / `wallpaper list` (below).

**nwg-look (`nwg-look`).** nwg-look shows what gsettings said when its window OPENED, and its Apply writes all of that back: an nwg-look
left open across a switch puts the old GTK theme back (on 2026-11-08 the user's had been open for hours and showed Colloid). The target
keeps nwg-look's own stored settings (`~/.local/share/nwg-look/gsettings`, what `nwg-look -a` applies) on the pair's gtk-theme, icon-theme
and color-scheme (its other lines -- cursor, font, sounds -- stay: no target sets those), and switches `export-gtk4-symlinks` off in
`~/.config/nwg-look/config` (the original kept for `restore`): with it on, nwg-look's Apply deletes `~/.config/gtk-4.0/gtk.css` and
`settings.ini` and links the GTK theme's own in their place. `doctor` names an nwg-look that is open. Neither file there is 'skipped'.

**libadwaita (`libadwaita`, `gnome-accent`).** libadwaita apps (loupe and zenity here) ignore the GTK theme: their stylesheet is built into
the library. What they do read is GTK 4's user stylesheet, `~/.config/gtk-4.0/gtk.css`, loaded over every GTK 4 app. The `libadwaita` target
writes it per pair and mode from `tools/theme/templates/libadwaita-gtk.css`: libadwaita 1.10's CSS variables set from the pair's tokens -- the
window, header bar, dialogs and popovers on the `surface`, views, cards and thumbnails on the carved `listBox`, sidebars on `panelSunk`, the text
`textPrimary`, and the pair's EXACT `accent` with `textOnAccent` on it; a status colour (ok, warn, error) takes whichever of the two inks reads best
on it (`{{warn|ink}}`: a warning yellow in a light mode reads ~2.4:1 with the light text-on-accent). Colours only: no widget is restyled, and
libadwaita's own shades, borders and opacities stay. A plain GTK 4 app (pavucontrol) keeps its GTK theme: a theme that reads none of these
variables is untouched (Colloid reads the accent one, and takes the pair's). The stylesheet wins over the settings portal with or without
`ADW_DISABLE_PORTAL` (the variable is no longer needed). GTK 4 reads the file ONCE, when an app starts: an open loupe keeps its colours until it
is opened again. Measured with the real libadwaita: `tools/dev/themectl_libadwaita_probe.py` (zenity in a headless sway beside a stand-in for this
desktop's portal; every variable the template sets is checked against the installed libadwaita's own stylesheet, so a rename shows). What was in
`gtk.css` first is kept for `restore` (a user's own file, or a link an install script's `--libadwaita` left).
`gnome-accent` still writes `org.gnome.desktop.interface accent-color`, the named GNOME accent (blue, teal, green, yellow, orange, red, pink,
purple, slate) nearest to the pair's `accent` by CIEDE2000 with the lightness taken out, for anything else that reads that key; libadwaita reads it
only when no portal answers (`tools/dev/themectl_accent_probe.py`), and the stylesheet's exact accent wins over it.

**Several wallpapers per theme.** `theme.wallpapers.<theme>.<mode>` in `shell.jsonc` is a path or a list of paths. Of a list, the
`wallpaper` target draws one from the slot's SHUFFLE BAG -- the lock's veil bag ported to Python (`modules/lockscreen/lock/VeilBag.js`;
`tools/dev/themectl_bag_parity.py` holds the two to one case table): a round shows each picture once, a new round never starts with the
picture the last one ended on, so any 2N-1 switches in a row show all N; a picture added mid-round shows within that round, one taken out
leaves it at once. A draw happens on a switch to another theme or mode and on the first apply of a new Hyprland session (the autostart's
`themectl apply`: the bag records `HYPRLAND_INSTANCE_SIGNATURE`); any other apply shows the current pick again. A missing file is left out
of the draw and named. The bags and each slot's pick are `~/.local/state/theme/wallpaper-bag.json`; `themectl wallpaper list [theme
[mode]]` prints a slot, its pick (`*`) and what is still to come in this round.

**Set as wallpaper (`themectl wallpaper set <image>`).** Exactly one image (jpeg, png, webp, jxl, bmp, judged by its first bytes) is ADDED
to the current theme and mode's list -- by an edit of `shell.jsonc`'s text (comments, layout and every other key stay; a string slot becomes
a list of two, one a line; a slot, a theme block, `wallpapers` or `theme` that is not there yet is inserted; a picture already listed is
not added twice; the path is written `~/...` under the home) -- and shown now (it counts as drawn), through the `wallpaper` target; a
notification with a **Revert** button says so (a detached copy of themectl waits for the answer, so the file manager is not blocked).
Revert takes the picture out of the list again (the old text byte for byte when the file is as the set left it, else only that item) and
puts the old picture back (as hyprpaper's fallback, the way every switch shows one). A refusal (several files, none, not an image, not a
file) is a notification too, and nothing is written.
**What the screen shows is read back.** hyprpaper 0.8 lets a picture set for a NAMED monitor beat the fallback until it restarts and
ignores the fallback request without a word, so after every request the `wallpaper` target reads `hyprctl hyprpaper listactive`: a monitor
that kept another picture is told by name, and one that still does not show it is a FAIL naming the monitor and what it shows (before
2026-11-11 a Revert into a theme with no slot named the monitor, and every later switch said `ok` while the picture stayed).
**Remove (`themectl wallpaper remove <image>`)** takes a picture out of the current list the same way; the picture on screen is replaced by
the next draw; the last picture of a list, or one not in it, is refused with nothing written.

**yazi.** Set and Remove are yazi's open menu (`O`), managed from yazi: `tools/theme/yazi/` holds the plugin `wallpapers.yazi` (a mark
`󰸉` in the linemode column beside every picture of the current theme and mode's list, read live from
`~/.local/state/theme/wallpapers-active.txt`), and `themectl install` sets it up once (the plugin copied, its `init.lua` line, a
`wallpaper-listed` opener -- your viewer, then "Remove from wallpapers" -- and BEGIN / END marks at the top of `[open] prepend_rules`;
originals kept). The `yazi` target then writes, on every switch, Set and Remove, one exact-path rule per listed picture between the marks:
a listed picture offers "Remove from wallpapers", every other image keeps "Set as wallpaper". The mark follows within a second; the menus
need a yazi restart (yazi reads `yazi.toml` at its start). The cheat sheet for a yazi update, and how to check and rebuild the plugin by
hand: `tools/theme/yazi/CHEATSHEET.md`. Proof on the installed yazi (a pty, a sandbox home): `python3 tools/dev/themectl_yazi_probe.py`.
Gates: `python3 tools/dev/themectl_cases.py` (C19 the read-back, C25 set, C27 the bag, C28 remove, C29 the rename, C30 nwg-look, C31
yazi), `python3 tools/dev/themectl_bag_parity.py`; the real hyprpaper in a nested Hyprland: `tools/dev/themectl_hyprpaper_env_probe.sh`
(`ARM=all`); the prompt already on screen, with the real kitty, starship and yazi: `tools/dev/themectl_prompt_env_probe.sh` (`ARM=all`);
the hidden windows: `python3 tools/dev/hidden_repaint_cases.py` (the plan), `tools/dev/hidden_repaint_env_probe.sh` (the tool against the
real Hyprland, nested; `HR_MODE=interrupt`, `HR_MODE=debug`, `HR_MODE=vscode` with a real VS Code given its class's frames, `ARM=all`), `tools/dev/curtain_repaint_env_probe.sh` (the real shell, the button clicked, one class given its own frames; `CR_MODE=debug`,
`CR_MODE=long` a ~5 s run with `ARM=fixedwatch`, `ARM=all`).

## Theme packages (GTK and the other app themes)

A pair's `assets.<mode>.gtkTheme` (and `iconTheme`, `vscodeTheme`) may be a **list, best first**: themectl takes the first one that
is installed, and when none is it takes the LAST, which is the theme the pair always used (so a machine that installs nothing gets
exactly the writes it got before). GTK counts a theme as installed when `~/.themes`, `$XDG_DATA_HOME/themes` or a `themes/` of
`$XDG_DATA_DIRS` holds a folder of that name with an `index.theme`, `gtk-3.0` or `gtk-4.0` in it; icons the same with an
`index.theme`; VS Code by the theme names its extensions and built-ins declare. `themectl doctor` prints a `pkg <pair>` line per pair
that has a list (`ok` when the best is installed, `note` with the missing names, the command that installs each and what it falls
back to; a note is never a FAIL), and `themectl packages` prints the install list for what is missing. What installs a name is
`tools/theme/packages.json` (`~/.config/theme/packages.json` over it). Nothing here installs anything.

Your installed copies of the themes (`~/.config/theme/themes/*.json`) are what themectl reads, not the repo's: the lists arrive with
`themectl install`, which replaces a copy older than the repo's and keeps a newer one (a copy you edited after the deploy keeps its
old `gtkTheme`; copy the pair's `gtkTheme` lines over by hand).

**Install list (2026-11-08; the AUR `yay -S --needed`, `extra` by pacman, VS Code by `code --install-extension`).** Every package is
optional: skip one and its pair falls back. Each pair's GTK list since the research of 2026-11-08
(`docs/agent_added_files_and_folders/themes_coverage.md`: the nearest installed GTK theme to the pair's own ground and accent,
by the stylesheets' colours), best first:

| Pair | light gtkTheme | dark gtkTheme | Installs | VS Code |
|---|---|---|---|---|
| eva | `Colloid-Light`, `XFCE_Colour_Lite_Doder` | `Colloid-Dark`, `XFCE_Colour_Dark_Doder` | `colloid-gtk-theme-git` | Eva Light / Dark Bold |
| catppuccin | `catppuccin-latte-mauve-standard+default`, `XFCE_Colour_Lite_Purple` | `catppuccin-macchiato-mauve-standard+default`, `XFCE_Colour_Dark_Purple` | `catppuccin-gtk-theme-latte catppuccin-gtk-theme-macchiato` | Catppuccin Latte / Macchiato |
| everbox | `Colloid-Teal-Light-Everforest`, `Colloid-Light-Everforest`, `XFCE_Colour_Lite_Beryl` | `Colloid-Teal-Dark-Gruvbox`, `Colloid-Dark-Gruvbox`, `XFCE_Colour_Dark_Beryl` | `colloid-everforest-gtk-theme-git colloid-gruvbox-gtk-theme-git` | Everforest Pro Light / Gruvbox Dark Medium |
| monokai | `Colloid-Teal-Light`, `XFCE_Colour_Lite_Beryl` | `Colloid-Teal-Dark`, `XFCE_Colour_Dark_Beryl` | `colloid-gtk-theme-git` (no Monokai GTK theme exists in the AUR) | Monokai Pro Light / Monokai Pro |
| night-owl | `adw-gtk3`, `Colloid-Light`, `Tokyonight-Light`, `XFCE_Colour_Lite_Doder` | `catppuccin-macchiato-blue-standard+default`, `Colloid-Dark`, `Tokyonight-Dark`, `XFCE_Colour_Dark_Doder` | `adw-gtk-theme` (extra), `catppuccin-gtk-theme-macchiato` (no Night Owl GTK theme exists) | Night Owl Light / Night Owl |
| paper | `adw-gtk3` | `Colloid-Dark`, `adw-gtk3-dark` | `adw-gtk-theme` (extra), `colloid-gtk-theme-git` | `Paper` (`a5hk.paper`) else Quiet Light / Kimbie Dark |
| riso | `Colloid-Pink-Light`, `XFCE_Colour_Lite_Pink` | `Colloid-Pink-Dark`, `XFCE_Colour_Dark_Pink` | `colloid-gtk-theme-git` | `Rosé Pine Dawn` / `Rosé Pine Moon` (`mvllow.rose-pine`) else Light Modern / Red |
| tokyo-night | `Tokyonight-Light`, `XFCE_Colour_Lite_Doder` | `catppuccin-macchiato-blue-standard+default`, `Tokyonight-Dark`, `XFCE_Colour_Dark_Doder` | `tokyonight-gtk-theme-git`, `catppuccin-gtk-theme-macchiato` (Macchiato Blue's ground is the nearest to Storm's; the hand-built `Tokyonight-Dark-Storm` is no longer listed) | Tokyo Night Light / Storm |

One line for all: `yay -S --needed catppuccin-gtk-theme-latte catppuccin-gtk-theme-macchiato colloid-gtk-theme-git colloid-everforest-gtk-theme-git colloid-gruvbox-gtk-theme-git tokyonight-gtk-theme-git && sudo pacman -S --needed adw-gtk-theme`;
VS Code: `code --install-extension a5hk.paper && code --install-extension mvllow.rose-pine`. `themectl packages` prints what is still
missing on the machine it runs on.

Re-checked 2026-11-08 for age and maintainer (the AUR RPC, every PKGBUILD read, the upstream repos): every package has been in the AUR
since 2024 or earlier. Colloid comes from Mark Wagie's `colloid-gtk-theme-git` split package (since 2021): the names without `-git`
that the first list had are a 2026-10-20 re-upload of the same PKGBUILD by a new account, 0 votes, with the release checksum skipped.
The Catppuccin packages pin the official 1.0.3 release zips by sha256 (checked against the downloads); catppuccin/gtk and
Tokyonight-GTK-Theme are archived upstream, so they will not change. The folder names were checked against the install scripts and zips.

What was found, so the choices can be questioned (read-only survey: `pacman -Ss`, the AUR RPC and PKGBUILDs, 2026-11-07; the names are the
folders the upstream install scripts make, read and not built here for lack of `sassc`, so the first install is the proof):

- **Today's themes**: the `XFCE_Colour_*` set (Beryl, Doder, Pink, Purple, Ruby, Yellow) is a 2018-2020 copy that no package owns, and it has
  **no GTK 4 folder and no `index.theme`**: GTK 4 apps get nothing from it. `adw-gtk3` has both.
- **libadwaita apps ignore `gtk-theme` entirely.** They follow `color-scheme` (themectl sets it), the accent in
  `org.gnome.desktop.interface accent-color` (only without a portal) and GTK 4's user stylesheet. Since 2026-11-08 themectl writes that
  stylesheet per pair (the `libadwaita` target, above): no package is needed for them, and the GTK themes' own `gtk-4.0` folders reach
  only plain GTK 4 apps.
- **Ranked GTK candidates**: catppuccin: `catppuccin-gtk-theme-latte/-macchiato` (exact palettes, release 1.0.3, packages updated up to 2025-12) > `colloid-catppuccin-gtk-theme` (Colloid with a Catppuccin scheme: a Latte/Frappe mix, no Macchiato) > mauve XFCE.
  tokyo-night: `tokyonight-gtk-theme-git` (Fausto-Korpsvart, upstream renamed Tokyonight-GTK-Theme and archived 2025-10) > `relic-tokyonight-gtk-theme` (a
  2025-10 fork of it with GTK 3/4 fixes, installs only a macOS-buttons build: names unchecked) > `Doder`. monokai, night-owl,
  paper, riso: no dedicated theme exists in the repos or the AUR (searched "monokai", "night-owl", "paper", "risograph"); `paper-gtk-theme-git`
  is snwh's 2018 Paper suite (a different Paper, last updated 2018). everbox: `colloid-*-gtk-theme-git` (Mark Wagie, 2021) > Fausto-Korpsvart's
  `everforest-gtk-theme-git` / `gruvbox-gtk-theme-git` (2024) > Beryl. Orchis (`extra/orchis-theme`, official repo) installs the blue
  `Orchis`, `Orchis-Light`, `Orchis-Dark` only: a fit for any blue pair if you would rather not use the AUR.
- **VS Code**: every theme name the pairs write exists on this machine (extensions `catppuccin.catppuccin-vsc`, `enkia.tokyo-night`,
  `monokai.theme-monokai-pro-vscode`, `sdras.night-owl`, `andreilucaci.everforest-pro`, `jdinhlife.gruvbox`, `fisheva.eva-theme`; built-ins
  Quiet Light, Kimbie Dark, Light Modern, Red for paper and riso). Nothing is missing; paper and riso have no extension of their own to add.
- **Icons**: Papirus (installed) is one family for every pair. `papirus-folders` (AUR, 1.14.0) recolours folders by rewriting
  `/usr/share/icons/Papirus*` as root through a pacman hook: there is no theme name to switch to, so themectl cannot use it per mode.
  `tela-circle-icon-theme-<colour>` (`extra`, ten-odd colours) are separate icon themes in an accent and could be listed in `iconTheme`, at the cost of a
  different icon style from Papirus: not added.
- **Cursors**: `catppuccin-cursors-latte` / `-macchiato` and `xcursor-simp1e-tokyo-night` / `-light` / `-storm` (AUR, 2025) exist; Nordzy is installed and used
  everywhere. Switching a cursor needs a target themectl does not have (gsettings `cursor-theme`, `hyprctl setcursor`): not added.
- **Qt / Kvantum**: neither `kvantum` nor `qt6ct` is installed, and only Catppuccin has a Kvantum theme (`kvantum-theme-catppuccin-git`, 2024): not worth a target.

## Settings

The `theme` block of `~/.config/quickshell/config/shell.jsonc` (read by `modules/shell/ThemeControl.qml` and `modules/shell/ShellConfig.qml`;
the commented example is `.examples/shell.jsonc`):

| Key | Meaning | Default |
|---|---|---|
| `apply` | `"shell"`: the button switches the shell alone; `"themectl"`: the whole desktop through `themectl` | `"shell"` |
| `curtain` | the curtain over the switch | `false` |
| `curtainStyle` | `"radial"`, `"peel"`, `"louvres"` or `"cycle"` | `"radial"` |
| `curtainLive` | with the curtain on, keep the shell live behind it | `false` |
| `targets` | which programs a switch by themectl touches: `{ "evince": false }` leaves one as it is (`lares` cannot be switched off; `--only` runs a target whatever this says) | all |
| `pairs` | the pairs the popup offers and `next` cycles, in this order; the pair in force is shown even when it is not listed | all, by name |
| `curtainRepaint` | with the curtain on, show the hidden workspaces and tabs under it so they repaint | `true` |
| `curtainRepaintFrames` | frames a window stays on show (1-60) when its class has no entry below | `3` |
| `curtainRepaintClassFrames` | window class -> frames (1-60); the class exactly as `hyprctl clients` says it, any case | `{}` |
| `curtainRepaintDebug` | switch without the curtain and run the repaint slowed and named, to watch it | `false` |
| `curtainRepaintDebugMs` | ms a step stays in the debug run (200-5000) | `900` |
| `wallpapers` | per theme and mode, a path or a list of paths (`themectl` applies one, drawn from a shuffle bag; `themectl wallpaper set` / `remove` and yazi's "Set as wallpaper" / "Remove from wallpapers" edit the list) | `{}` |
| `wallpaperFit` | `"cover"`, `"contain"`, `"tile"` or `"fill"` | `"cover"` |

Before setting `apply` to `"themectl"`, run `tools/theme/themectl doctor` and add the lines it asks for (or `themectl migrate`).

The popup's look and motion (card size, float, tilt, strands) are tuned in `mockups/theme.qml`; Save writes
`modules/theme/ThemeStyle.qml`.

## How it is built

| File or directory | Role |
|---|---|
| `modules/common/theme/Theme.qml` | the palette every component reads (`Theme.<token>`), the state file, the crossfade's one clock |
| `modules/common/theme/ThemeResolve.js` | reads a theme file's tokens and recipes (the same rules as `themectl`'s) |
| `modules/shell/ThemeControl.qml` | the switch: the right click, a card's pick, the `themectl` child, the curtain's sequence |
| `modules/shell/ThemeBarButton.qml` | the swatch icon (the filled swatch in both modes, the busy / failed tints, the flourish's clock) |
| `modules/shell/parts/SwatchPose.js`, `SwatchParts.js` | the flourish: the motion and its numbers (`DEFAULTS`); the glyph's outline, generated by `tools/dev/flourish_parts.py` |
| `modules/shell/ThemeCurtain.qml`, `ThemeCurtains.qml` | the curtain: one window per screen holding the picture |
| `modules/shell/ThemeWipe.qml` | the live curtain (`curtainLive`) |
| `tools/theme/hidden_repaint.py` | shows the hidden workspaces and tabs by turns (one Lua chunk Hyprland runs on its own timers) and puts the session back; `plan` prints what a run would do, changing nothing |
| `modules/theme/ThemeBarOwner.qml` | opens and closes the popup |
| `modules/theme/ThemePopup.qml`, `ThemePairRow.qml`, `ThemeCard.qml`, `ThemeCardFace.qml`, `ThemeStrands.qml` | the popup: rows, cards, the mini desktop, the strands |
| `modules/theme/data/ThemePairs.qml`, `FloatMotion.js` | the list of themes and their colours; a card's float and tilt |
| `modules/theme/ThemeStyle.qml` | every number of the popup |
| `modules/theme/IslandGround.qml`, `modules/theme/shaders/` | the popup's ground through a switch; the cards' and strands' shaders |
| `themes/` | the shipped theme files |
| `tools/theme/` | `themectl`, its `targets.json`, `packages.json` (what installs each preferred theme name), `templates/`, the Windows VM agent, `pairgen.py` (a pair from its source palette), `btop/` and `fastfetch/` (what the btop and fastfetch targets ship), `yazi/` (the wallpapers.yazi plugin and its cheat sheet) |

Shared pieces: `ThemeCrossfade` (each window's crossfade), `ThemeIsland` + `FadeColor` (a part that keeps moving through a fade),
`Mix.js` (mixing two themed colours by a fraction), all in `modules/common/components/`.

## Limits

- A colour is never written into a component: components read `Theme.<token>`. A colour that does not follow a switch is a hex
  left in a component.
- With `apply: "shell"` only the shell changes; kitty, GTK, the borders and the wallpaper keep their mode.
- Without the curtain (or with `curtainRepaint` off) windows on hidden workspaces and hidden tabs repaint when they are next shown,
  a frame or two late. With it, three kinds still do: a window of a fullscreen workspace, an app slower than its turn under the
  curtain (give its class more frames in `curtainRepaintClassFrames`), and a window opened later by an app that reads its theme
  late (VS Code at its start).
- A setting of the theme block that is out of range is replaced by its default AND said in a notification.
- The frame counts are the panel's and the app's: in a nested Hyprland at 60 Hz one frame was enough for kitty, on the user's
  120 Hz panel it takes 2, VS Code about 16 and zen about 24 (their measurements). Frames are counted on the slowest monitor. The
  shell's log has one line per run (`LARESCURTAIN ctl ... repaint: REPAINT ok steps=.. ms=.. frames=<per step>`), and the curtain
  holds as long as the run takes.
- The app icon theme follows the mode through gsettings, but the shell reads it when it starts: icons change at its next restart.
- The curtain and the live curtain are prototypes.

## How to change it

- **A colour of a theme**: open any module's mockup (`quickshell -p ~/.config/quickshell/mockups/<id>.qml`), change the colour on
  its theme rows and Save: it is written into the theme file in force (`~/.config/theme/themes/<name>.json`, or the repo's when that
  does not exist). Or edit the JSON by hand; the shell picks the change up. Then `tools/dev/theme_sync_probe.sh`; the cards' float (shared with notes and weather,
  `modules/common/float/`) by `tools/dev/float_probe.sh`.
- **A new theme**: add a spec for it to `tools/theme/pairgen.py` (the source's surface, text, accent, status colours, hues and 16
  terminal colours) and run `python3 tools/theme/pairgen.py --write <name>`: it derives the other ~170 colours by eva's rules and writes
  `themes/<name>.json` (and a custom btop theme when the spec names one). Or copy `themes/eva.json` to `themes/<name>.json` and edit it by
  hand. Either way, check it with `tools/dev/bar_hues_table.sh` and `python3 tools/dev/themectl_cases.py` (they hold every theme on disk
  to the rules), then `tools/theme/themectl install`. It appears in the popup at its next open. Do not re-run pairgen over a pair that
  was tuned by hand afterwards: it rewrites the whole file.
- **Which programs follow the theme**: `tools/theme/targets.json` and `tools/theme/templates/`; `tools/theme/themectl diff` shows
  what an apply would change. Gates: `python3 tools/dev/themectl_cases.py`; the real programs reading every theme:
  `python3 tools/dev/themectl_programs_probe.py` (kitty, btop; `HYPR=1` adds Hyprland in a nested session); libadwaita's colours and accent drawn by the
  real libadwaita in a headless sway: `tools/dev/notifications_bus.sh python3 tools/dev/themectl_libadwaita_probe.py` (the stylesheet) and
  `.../themectl_accent_probe.py` (the named accent). A review sheet of every
  pair (the bar, four popups, the lock popup, light and dark): `python3 tools/dev/theme_pair_sheet.py <outdir>`.
- **The popup's look**: `mockups/theme.qml`, Save, then `tools/dev/smoke.sh mockups/theme.qml`.
- **The button's flourish**: the numbers are `DEFAULTS` at the top of `modules/shell/parts/SwatchPose.js` (how far it leans, how
  long the turn takes and how far it lands past its place, how much later each card behind follows, what it turns about, the hop);
  the run's length follows them. Look at it frame by frame with `ONLY=theme WHAT=strip tools/dev/glyph_flourish_strip.sh <outdir>`
  (add `THEMESCALE=4 ZOOM=1` for a true 4x render), then `tools/dev/glyph_flourish_probe.sh` (the glyph is the font's outline at
  the run's two ends; no card is ever drawn over the card in front; the glyph is the same in dark: ARMs swatchlate, overfront,
  darkoutline). After a Nerd Font update: `python3 tools/dev/flourish_parts.py`
  (`--check` says when the outlines are stale). To keep it out of the random turns: `"oled": { "flourishes": { "glyphs": { "theme":
  false } } }` in `config/shell.jsonc` (a hover still plays it).

Contract (for developers): [contracts/theme.md](contracts/theme.md).
