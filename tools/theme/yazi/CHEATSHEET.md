# wallpapers.yazi: cheat sheet

Version 1 (2026-11-08), for yazi 26.9.1. Several wallpapers per theme, managed from yazi: a mark beside every
picture of the CURRENT theme and mode's list, "Remove from wallpapers" on those pictures only, and "Set as
wallpaper" (= add to the list and show it now) on every other image.

## What you see

| where | what |
|---|---|
| the linemode column (right end of a row, after the size) | `󰸉` in blue beside every picture of the current theme and mode's list (`theme.wallpapers.<theme>.<mode>` in `shell.jsonc`). The list is the one `Set` adds to and `Remove` takes from |
| Enter on any image | your viewer (the first entry of your `[opener] image`) |
| `O` (open with) on a listed picture | "view image", "Remove from wallpapers" |
| `O` on any other image | "view image", "Set as wallpaper" |

- **Set as wallpaper** adds the picture to the current theme and mode's list (a picture already there is not added
  twice) and shows it now. A notification says so, with a **Revert** button (takes it out of the list again and
  puts the old picture back).
- **Remove from wallpapers** takes it out of the list. If it is the picture on screen, the next one is drawn and
  shown. The last picture of a list is refused (nothing changes; set another one first).
- **Which picture shows.** A list is a shuffle bag, like the lock's veils: every switch to the theme (or to the
  mode) and the first `themectl apply` of a new session (your autostart runs one) draws the next picture; inside a
  round each picture comes once, and a new round never starts with the one that ended the last, so any 2N-1
  switches in a row show all N pictures. An apply in the same session, theme and mode keeps the picture.
  `themectl wallpaper list` shows the list, the one on screen (`*`) and how many are still to come in this round.
- **Timing.** The MARK follows at once: the plugin reads the list again at most once a second, on the next redraw
  (move the cursor). The MENU ("Remove" vs "Set") is in `yazi.toml`, which yazi reads only when it starts: a yazi
  that was already open before a switch, a Set or a Remove offers the old menus until you restart it.

The pieces:

| file | who writes it | what |
|---|---|---|
| `~/.config/yazi/plugins/wallpapers.yazi/main.lua` | `themectl install` (a copy of `tools/theme/yazi/wallpapers.yazi/main.lua`) | the mark |
| `~/.config/yazi/init.lua` | `themectl install`, once | the line that switches the plugin on |
| `~/.config/yazi/yazi.toml` `[opener] wallpaper-listed` | `themectl install`, once | "view image" (your own viewer, copied) + "Remove from wallpapers" |
| `~/.config/yazi/yazi.toml` `[open] prepend_rules`, between the BEGIN / END lines | `themectl`, on every theme switch, Set and Remove (the `yazi` target) | one exact-path rule per listed picture, before your image rule |
| `~/.local/state/theme/wallpapers-active.txt` | `themectl`, the same times | the list the plugin reads (one absolute path a line) |
| `~/.local/state/theme/wallpaper-bag.json` | `themectl` | each list's shuffle bag and the picture on screen |

## 1. The lines (themectl install adds them; here to check, or to add by hand)

`themectl install` makes these edits once (anchors found or nothing written, the originals kept: `themectl restore
yazi` puts `yazi.toml` and `init.lua` back and removes the plugin). By hand:

`~/.config/yazi/init.lua`, anywhere:

```lua
pcall(function() require("wallpapers"):setup() end)   -- themectl: the wallpaper mark (a broken plugin only loses the mark)
```

`setup` takes options, every one optional: `require("wallpapers"):setup { sign = "*", color = "magenta", order = 1600 }`
(`order`: where in the linemode it stands; git.yazi's sign is 1500 in your init.lua, so the mark comes after it).

`~/.config/yazi/yazi.toml`:

```toml
[opener]
wallpaper-listed = [
    { run = "loupe %s", block = false, orphan = true, desc = "view image" },          # copied from your image opener: Enter views
    { run = "/home/user/.local/state/lares/shell/current/tools/theme/themectl wallpaper remove %s", block = false, orphan = true, desc = "Remove from wallpapers" },
]
image = [
    { run = "loupe %s", block = false, orphan = true, desc = "view image" },
    { run = '/home/user/.local/state/lares/shell/current/tools/theme/themectl wallpaper set %s', block = false, orphan = true, desc = "Set as wallpaper" },
]

[open]
prepend_rules = [
    # BEGIN themectl wallpapers -- themectl writes the rules between these two lines on every theme switch and wallpaper change
    # END themectl wallpapers
    { mime = "image/*", use = "image" },
    # ... your other rules
]
```

Keep "Remove from wallpapers" SECOND in `wallpaper-listed`: Enter runs the first entry. The two marks must stay
inside `prepend_rules` and before your image rule (the first rule that matches wins). `prepend_rules` must be one
rule a line (install refuses a one-line list). The generated rules look like
`{ url = "\\s/home/user/Pictures/wallpapers/x.jpg", use = "wallpaper-listed" },` -- `\s` makes the match
case-sensitive, and a glob character in a file name is put in a class of its own (`x[[]1[]].png` for `x[1].png`):
yazi matches `url` as a glob against the whole path, with no backslash escapes. Never edit between the marks:
themectl rewrites that part.

## 2. What happens at a yazi update

Only the MARK is code. It uses three things of yazi's plugin API and nothing else:

| API | used for | breaks how |
|---|---|---|
| `Linemode:children_add(fn, order)` | a column of the linemode, right-aligned | renamed or removed: `setup` raises, `pcall` in init.lua swallows it, no mark |
| `self._file.url`, `self._file.is_hovered` | the row's file (`tostring(url)` is its path) | renamed: the column's own `pcall` returns "", no mark |
| `ui.Line`, `ui.Span`, `ui.Style():fg()` | the mark's text and colour | the same |

plus plain Lua (`io.open`, `os.time`, `os.getenv`). Every failure ends as "no mark"; yazi itself keeps working. The
menus are plain config (`[opener]`, `[open] prepend_rules`, `url` / `use`): a yazi that changes that format says so
at its start ("Error ... yazi.toml") and the menus are gone until the lines in section 1 are put in the new shape.

The same column API is what git.yazi uses (the `` signs in a repo): when `ya pkg upgrade` brings a git.yazi that
calls `Linemode:children_add` or reads `self._file` differently, make the same change here.

## 3. Checking it, and rebuilding it by hand

```
python3 ~/.config/quickshell/tools/dev/themectl_yazi_probe.py     # under a minute: the INSTALLED yazi on a pty, in a sandbox HOME
```

Its last line is `THEMECTL_YAZI RESULT PASS` or `FAIL`. It runs `themectl install` in a sandbox home, starts
yazi in a folder of five pictures and reads its screen: Y1 yazi starts with the plugin and the rules and shows no
error; Y2 the listed pictures (one named `x[1].png`) carry the mark and the others not; Y3 `O` offers "Remove" on a
listed picture and "Set" on another image; Y4 the mark follows a mode switch while yazi runs. It never touches your
yazi, your config or your pictures (it proves that nothing outside the sandbox changed). Run it after every yazi
update. `ARM=all` breaks each part on purpose and checks that the probe notices.

By hand: open yazi in a folder of your current wallpapers. No mark: run `yazi --debug` (it prints the version and
the plugin paths) and start it with `YAZI_LOG=debug yazi`, then read `~/.local/state/yazi/yazi.log` for
`wallpapers`. `themectl doctor` has a `yazi` line that names whatever of section 1 is missing.

Rebuilding: the plugin is the 66 lines of `main.lua`; the comments say what each part does. Edit
`~/.config/yazi/plugins/wallpapers.yazi/main.lua`, restart yazi, look. Then copy it back to
`~/.config/quickshell/tools/theme/yazi/wallpapers.yazi/main.lua` (a copy in yazi's folder that is newer than the
repo's is yours: `themectl install` keeps it and never overwrites it). Re-run the probe.

## 4. The API, with links

- yazi's plugin docs: <https://yazi-rs.github.io/docs/plugins/overview>; `ui.Line` / `ui.Span` / `ui.Style`:
  <https://yazi-rs.github.io/docs/plugins/layout>; sync and async contexts (why the list is re-read by the clock
  and not by its mtime: `fs.cha` is async only): <https://yazi-rs.github.io/docs/plugins/utils>
- `Linemode` itself (its `_file`, `children_add`, how the children are drawn):
  <https://github.com/sxyazi/yazi/blob/main/yazi-plugin/preset/components/linemode.lua>
- the working example of the same column: git.yazi, <https://github.com/yazi-rs/plugins/blob/main/git.yazi/main.lua>
  (your copy: `~/.config/yazi/plugins/git.yazi/main.lua`)
- `[opener]`, `[open]` and the `url` glob of a rule: <https://yazi-rs.github.io/docs/configuration/yazi>; how a
  `url` pattern is matched (the whole path; `\s`; no backslash escapes):
  <https://github.com/sxyazi/yazi/blob/main/yazi-config/src/pattern.rs>
- yazi's changelog (look for `Linemode`, `children_add`, `File`, `opener`, `prepend_rules`):
  <https://github.com/sxyazi/yazi/releases>
