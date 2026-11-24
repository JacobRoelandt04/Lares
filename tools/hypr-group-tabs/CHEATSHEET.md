# hypr-group-tabs: cheat sheet

Version 0.3.1 (2026-11-07). A window group's tabs as part of the window's BORDER, reserving no
space: a grouped window has exactly the geometry of an ungrouped one.

## What you see

The top border is your normal border all the way across. The tab of the window on show takes
its share of the border's straight top edge (a group of 2: half, of 4: a quarter), and along
that share the border runs from its own colour at both ends to the tab colour in the middle.
Everything else is the plain border, so the share's size tells roughly how many windows the
group holds, and there is no edge anywhere for the eye to catch.

| state | tab colour (all from your Lua config) |
|---|---|
| focused group | `group.groupbar.col.active` |
| focused, locked | `group.groupbar.col.locked_active` |
| unfocused group | `group.groupbar.col.inactive` (equal to the inactive border: nothing shows) |
| unfocused, locked | `group.groupbar.col.locked_inactive` |

The border around it is the one Hyprland gives a grouped window (`group.col.border_*`). When the
focus comes or goes, the tab colour fades with the border, on the border's own animation
(`border` in animations.lua): one clock.

A window your rules leave WITHOUT a border (`border_size = 0`: yazi, rlr, the game/photo/video
content types, and maximized windows through your `fullscreen = true` rule, which Hyprland also
matches for a maximized window) gets your normal border (`general.border_size`, the group's
colours, the tab) for as long as it is in a group; out of the group your rule is back. So the tab
of a group can always be seen and used, whichever member is on show.

- Tiled, the forced border makes the window exactly the size of the other members (each member
  takes its own border off the group's box; a borderless one used to be 3 px larger on every side).
- Floating (yazi), the window's box is the group's and does not change; the border is drawn
  outside it, as on every floating window.
- Real fullscreen still has no border and no tab. Maximized under your fullscreen rule it gets the
  border with square corners (that rule's `rounding = 0`).
- Not forced: a window with `decorate = false` (no decorations at all) and an X11 window that asks
  for no border itself. Neither is a border width; Hyprland draws no border for them whatever the
  width says.
- How: the plugin writes the border width where `hyprctl setprop <window> border_size` writes it,
  and takes it back when the window leaves the group, when you set `enabled = false`, and when the
  plugin is unloaded. A `setprop border_size` you make on a grouped window wins over it (a
  `setprop ... 0` is forced over again while the window is grouped); one you made before grouping
  comes back when it leaves. `hyprctl getprop <window> border_size` shows the width in force.

The pointer: on the tabs (the top border's three pixels, between the corner arcs) your move bind
(`SUPER + mouse:272`, `hl.dsp.window.drag()`) pulls THAT tab's window out of the group and drags
it, as the vanilla groupbar did; anywhere else, or in a group of one, it moves the window as
always. A left click on a tab shows that window. (The vanilla bar's middle-click close is left
out on purpose: a stray middle click on a band three pixels tall would close a window.)

Why it cannot stand a pixel off the border any more: 0.1 and 0.2 drew rectangles OVER the border
and had to reproduce its arithmetic; at some window positions, scales and render transforms they
landed a row off. 0.3 draws no overlay. It hooks Hyprland's own border render step
(`Render::GL::CGLElementRenderer::draw` for the border pass element) and, for a grouped window,
draws the very same border (same box, same shader, same width, same fade state) cut by clip
rectangles: the tab's share of the top edge with a gradient of its own, the rest as it was. Every
piece covers exactly the pixels the border covers. The proof (section 5) compares the plugin's
border with the vanilla border of the same window, pixel for pixel, at every fractional window
position at scales 1, 1.25 and 1.5: only the tab's share of the band's rows differs.

## 1. The lines in your Lua config (NOT applied by anyone but you)

Load it from `autostart.lua`, next to glasscope (inside the same `HYPR_NO_PLUGINS ~= "1"`
block, so the TTY escape below also skips it):

```lua
hl.exec_cmd("hyprctl plugin load " .. os.getenv("HOME") .. "/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so")
```

`appearance.lua`, `group` block. The guard keeps the vanilla groupbar for a start on which the
plugin did not load (after an update), so you are never left with no indicator. With the tabs on
the border, a locked group's border is your normal border too (the lock shows in the tab's
colour); without that, a locked group would get a whole border in another colour:

```lua
group = {
    col = {
        border_active          = "rgb(" .. border_active .. ")",
        border_inactive        = "rgb(" .. border_inactive .. ")",
        border_locked_active   = "rgb(" .. border_active .. ")",     -- was border_group_locked
        border_locked_inactive = "rgb(" .. border_inactive .. ")",   -- was rgba(... CC)
    },
    groupbar = {
        enabled = (hl.plugin.group_tabs == nil),   -- vanilla bar only while the plugin is absent
        indicator_height = 3,
        col = {
            active          = "rgb(FE8019)",       -- the TAB colour: an accent, not the border's (gruvbox orange here)
            inactive        = "rgb(" .. border_inactive .. ")",
            locked_active   = "rgb(" .. border_group_locked .. ")",
            locked_inactive = "rgba(" .. border_inactive .. "CC)",
        },
        -- everything else stays (the vanilla bar still reads it when the plugin is absent)
```

themectl's generated `config/theme.lua` sets these same colours again (after appearance.lua and on
every `themectl apply`). Until its template carries a tab colour of its own, it sets
`groupbar.col.active` to the BORDER colour, and then the tab of a focused group is invisible
(border colour to border colour). The change to themectl's template is requested in this round's
report; once it is in, the theme decides the tab colour and the lines above are only for a start
without themectl.

Optional, in `plugins.lua` (the values shown are the defaults):

```lua
if hl.plugin.group_tabs then
    hl.config({ plugin = { group_tabs = { enabled = true, fade = 0.5 } } })
end
```

| option | default | what |
|---|---|---|
| `plugin:group_tabs:enabled` | true | the tabs at all (false: the plain border, and a borderless window's forced border goes back to its rule at once; the vanilla bar stays off while the plugin is loaded) |
| `plugin:group_tabs:fade` | 0.5 | the share of the tab, from each end, over which it runs from the border colour to the tab colour: 0.5 a peak in the middle, 0.25 a flat middle half, 0 a flat tab with hard ends |

0.2's `thickness`, `gap` and `corner_margin` are gone: the tab is the border's own band, the tabs
need no gap when only one of them is drawn, and the tab fades into the border at both ends.
(Hyprland answers a line that still sets one with `unknown config key
'plugin.group_tabs.gap'`: take them out of `plugins.lua` if you added them.)

You do the first load yourself, by hand, with a terminal open (section 4):

```
cd ~/.config/quickshell/tools/hypr-group-tabs && make        # builds hypr-group-tabs.so
make install                                                  # copies it to ~/.local/lib/hyprland-plugins/hypr-group-tabs/
hyprctl plugin load ~/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so
```

Nothing above needs sudo or hyprpm. If 0.3 or 0.2.1 is loaded, unload it first (both unload
safely with a group up; 0.1 and 0.2 do not: never unload those two with a group open). The unload
of 0.3.1 gives every forced border back (the nested test unloads with a borderless window grouped
and on show).

## 2. What happens at a Hyprland update

A plugin is machine code that reaches into Hyprland's own C++ classes (window, decoration, render
pass). Their layout can change in any release without a compile error in the plugin. So there are
guards, and all of them refuse on purpose:

1. Hyprland: `hyprctl plugin load` refuses a plugin whose `PLUGIN_API_VERSION` differs.
2. The plugin itself: at init it compares the running Hyprland's commit hash with the hash of the
   headers it was built from, and refuses with "Version mismatch" (and a red notification). It
   also refuses ("... not found in this Hyprland" / "could not hook ...") when the border render
   step it hooks is missing or renamed. Both refusals happen before anything is registered.
3. hyprpm (only for plugins it manages): it keeps the hash of the Hyprland it built everything for
   in `/var/cache/hyprpm/$USER/state.toml` and refuses to load a plugin when the running Hyprland,
   or one of its libraries, differs ("Headers version mismatch. Please run hyprpm update", "ABI is
   mismatched"). It cannot tell whether the part of the API a plugin uses changed, so it refuses
   all of them, including the ones that would still work. That is the cost of a check that never
   lets a stale plugin crash the compositor.

`pacman -Syu` installs new headers at once (where they are: "Version mismatch" in section 3), but the
RUNNING Hyprland stays the old binary until you log out. So: update, log out and in (the plugin is refused, the
vanilla bar returns thanks to the guard in section 1), THEN rebuild, so headers == running binary.
Or rebuild before logging out and test in the nested env (section 5), which runs the NEW binary.

## 3. Rebuilding

```
cd ~/.config/quickshell/tools/hypr-group-tabs
make status                 # the four hashes (below); read only
make                        # builds when a source OR the Hyprland headers' hash changed; needs g++, pkgconf, the
                            # hyprland package (headers), libdrm, libinput, pixman, wayland. `make clean && make` forces it.
make install                # user-only copy, no sudo
hyprctl plugin unload ~/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so   # if an older one is loaded
hyprctl plugin load   ~/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so
```

Build errors are the good outcome: they name the header member that moved.

### "Version mismatch (headers are not the running Hyprland)"

That load error is not a line to edit. The plugin carries a 40-character commit hash, compiled INTO
the .so from the headers it was built against: `src/version.h` there says
`#define GIT_COMMIT_HASH "..."`. At load, `main.cpp` compares the running Hyprland's hash
(`__hyprland_api_get_hash()`) with that one (`__hyprland_api_get_client_hash()`) and refuses when
they differ. So the error means the .so was built from other headers than the Hyprland that runs,
and the cure is a build from the current headers. Never an edited hash: the check compares COMMITS,
not APIs, and it is the one thing that stops a plugin built for another Hyprland's class layouts
from crashing the compositor (section 4). Even a release that changed nothing the plugin uses
(0.57.1 to 0.57.2: `api-diff.sh` says `same` everywhere) needs the rebuild.

`make status` prints the four hashes that must agree:

```
headers   11cbc6c5...  (.../hyprland/src/version.h)   what a build made now would carry
running   11cbc6c5...  (hyprctl version)              what the compositor compares with
built     acc1aa0b...  (hypr-group-tabs.so)           this folder's build
installed acc1aa0b...  (~/.local/lib/...)             what autostart.lua loads
```

By hand: `hyprctl version` (the hash after "at commit"), `grep GIT_COMMIT_HASH <headers>/src/version.h`,
`strings hypr-group-tabs.so | grep -E '^[0-9a-f]{40}$'`. Which pair differs says what to do:

* built differs from headers: `make`. It reads the headers' hash on every run (kept in
  `.hyprland-hash`) and rebuilds when it moved. Before 2026-11-10 it only watched the plugin's own
  files, so after an update a plain `make` built nothing and `make install` copied the old build:
  that is the mismatch you saw on 11-10, with "built" and "installed" still 0.57.1's acc1aa0b.
* installed differs from built: `make install`.
* headers differ from running: the update is installed but this session still runs the old
  Hyprland. Log out and in, or test the new build in the nested env first (section 5).
* all four equal: `hyprctl plugin load ...` (or log in again: autostart.lua loads it).

Where the headers are: wherever pkg-config's `hyprland.pc` points. The hyprland package installs it
pointing at `/usr/include/hyprland`, and `hyprpm update` rewrites that same file to point at its
own copy (`/var/cache/hyprpm/$USER/headersRoot/include`, what this machine says today; `pacman -Qkk
hyprland` reports the file as modified because of it). After an update both are the new version;
`make status` names the file it read.

The plugins you do manage with hyprpm (dynamic-cursors, HyprGlass):

```
hyprpm update           # after logging in to the NEW Hyprland. Clones the Hyprland sources for the
                        # running commit, builds headers, rebuilds every plugin, re-enables them.
                        # SUDO: it asks for your password to install the headers into
                        # /var/cache/hyprpm/$USER (root-owned). Needs git, cmake, meson, ninja, cpio, pkgconf (all installed).
hyprpm update -f        # same, ignoring "already up to date" checks
hyprpm list             # what is installed / enabled
hyprpm reload           # load every enabled plugin into the running Hyprland (autostart.lua does this)
```

If you want this plugin under hyprpm too: hyprpm needs `hyprpm.toml` at the ROOT of a git
repository, and this directory sits inside the quickshell repo. Make a repo of a copy of the folder
(`git init`, commit) and `hyprpm add /path/to/that/repo`, `hyprpm enable hypr-group-tabs`. Not
needed for the by-hand route above.

## 4. Loading by hand, and seeing that it broke

```
hyprctl plugin load /full/path/hypr-group-tabs.so    # prints ok, or the reason
hyprctl plugin list                                  # is it there? (Version: 0.3.1)
hyprctl plugin unload /full/path/hypr-group-tabs.so
hyprctl -j getoption plugin:group_tabs:fade          # the config values exist only while it is loaded
```

It broke if: `plugin list` has no hypr-group-tabs; the load printed an error; a red
"[hypr-group-tabs] ..." toast appeared at login; the vanilla groupbar is back (the guard) after an
update; or a grouped window's top border shows no tab. The log:
`$XDG_RUNTIME_DIR/hypr/<signature>/hyprland.log` (`ls $XDG_RUNTIME_DIR/hypr/`),
`~/.cache/hyprland/hyprlandCrashReport*.txt` for a crash.

If it crashes the compositor (a plugin runs inside it: a bad ABI is a segfault, and every window
dies with it):

* From a TTY (Ctrl+Alt+F3), log in, then EITHER start with plugins off:
  `HYPR_NO_PLUGINS=1 start-hyprland` (your autostart skips `hyprpm reload` and every
  `hyprctl plugin load`; with the guard the vanilla groupbar is on), OR move the file away so the
  load simply fails: `mv ~/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so{,.off}`.
* Then rebuild (section 3) and test in the nested env (section 5) before loading it in the session
  again.
* Kill switch without a crash: `hl.config({ plugin = { group_tabs = { enabled = false } } })` (the
  plain border, at once) or `hyprctl plugin unload ...` (the nested test proves an unload with a
  group of two open, and a config reload with the plugin loaded).

## 5. Test it without risking the session, and tell whether the API changed

```
tools/hypr-group-tabs/test.sh            # ~4 min, nested headless Hyprland (tools/dev/lock_env.sh), never your session
ARM=1 tools/hypr-group-tabs/test.sh      # the same probe with the plugin off: it must fail (a vanilla bar reserves space)
ARM=force tools/hypr-group-tabs/test.sh  # a build that never forces the border: the borderless checks must fail
ARM=release tools/hypr-group-tabs/test.sh  # a build that never gives it back: the "rule is back" checks must fail
```

Run it after every Hyprland update, after `make`, BEFORE the first load in the real session. It
uses the Hyprland binary installed on the machine, so it works the moment the package is updated,
before you log out. Its last line is `GROUPTABS RESULT PASS` or `FAIL`. It loads the .so into that
nested instance and checks: a grouped window has the geometry of an ungrouped one; against the
vanilla border of the same window only the tab's share of the band's rows differs, all of it, its
middle the tab colour and its ends the border colour (scale 1 and 1.25, the focused, unfocused and
locked colours, groups of 1, 2 and 4, a second output); the same over every fractional position at
scales 1, 1.25 and 1.5 (the sweep); fullscreen has no border and no tab; a click on a tab selects
it; the move bind on a tab pulls that window out of the group (the virtual pointer), off the tabs
it moves the whole group; a window with `border_size = 0` by rule, grouped: the border and the
tab, its size the other member's, its border pixel for pixel a bordered member's but for the tab
(scales 1, 1.25 and 1.5, tiled and over a floating sweep), maximized under a fullscreen no-border
rule, fullscreen, a click and the drag-out on its band, out of the group no border, grouped and
ungrouped five times over, closed while grouped; an unload with that window grouped and on show
(its border given back), a load (forced again) and a config reload. (`SO=<another build>` tests
another build; `SWEEP_ONLY=1` runs only the sweep; `FORCE_ONLY=1` only the borderless window and
the unload.)

Did the update change what the plugin uses?

```
tools/hypr-group-tabs/api-diff.sh v0.57.1 v0.58.0    # old and new tag, read-only, fetches from GitHub
```

It diffs the files the plugin depends on (the decoration and positioner headers and sources, the
border pass element and its GL renderer, `renderBorder` and the border and gradient shaders it
mirrors, groups, the mouse action that asks decorations for a drag, the plugin API, and for the
forced border the window's rule properties and their priorities, and the plugin unload order). `same` on all
of them is a good sign; `CHANGED` on one is where a compile error, or a silent difference, will come
from. Compile errors and a red `test.sh` are the two signals; trust neither alone: a moved member
compiles and only the picture shows it.
