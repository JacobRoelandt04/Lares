#!/usr/bin/env bash
# Proof for hypr-group-tabs, in the isolated nested Hyprland of tools/dev/lock_env.sh
# (headless mutter + a nested Hyprland with a private runtime, config and bus).
# It never touches the user's session: no hyprctl, hyprpm or plugin call reaches it.
#
#   tools/hypr-group-tabs/test.sh            full run (~2 min), last line GROUPTABS RESULT PASS|FAIL, exit status = verdict
#   ARM=1 tools/hypr-group-tabs/test.sh      the same probe with the plugin unloaded and the vanilla groupbar back: it MUST
#                                            fail (the geometry check sees the space the bar reserves)
#   ARM=force tools/hypr-group-tabs/test.sh  section K + I on a build that never forces the border (-DGROUP_TABS_ARM_NO_FORCE): the
#                                            forced checks MUST fail (forced_geometry, forced_tab_scale1)
#   ARM=release tools/hypr-group-tabs/test.sh  the same on a build that never gives the border back (-DGROUP_TABS_ARM_NO_RELEASE):
#                                            forced_drag_out and forced_ungrouped_no_border MUST fail
#   KEEP_SHOTS=1                             keep the screenshots in $OUT
#   SO=/path/hypr-group-tabs.so              test another build (an armed one, to see a check fail on it)
#   SWEEP_ONLY=1                             only the grid sweep (section J)
#   FORCE_ONLY=1                             only the borderless window (section K) and the unload (section I)
#
# The look (0.3): the top border is the window's own border all the way across; the selected tab's share of its straight part runs from
# the border colour at its ends to the tab colour (group:groupbar:col.*) in the middle. It is drawn BY the border's own pass element (the
# plugin hooks the border's render step and draws the same border cut by clip rectangles), so the reference for every pixel is the vanilla
# border of the same window: plugin:group_tabs:enabled = false draws exactly that.
#
# What it proves, by numbers:
#   geometry  : a grouped window has exactly the `at`/`size` of the same window ungrouped
#   identity  : against the vanilla border of the same window, the pixels that differ are ONLY inside the selected tab's segment (its
#               columns, the border's own band rows), every band row of the segment's middle differs, and the segment's middle is the tab
#               colour, its ends the border colour (no step where it meets the border)
#   sweep     : the identity at scale 1, 1.25 and 1.5 over every fractional position a floating window can stand at
#   colours   : the focused / unfocused / locked tab colours; the segment follows focus and the member count (groups of 1, 2, 4)
#   input     : the move bind pressed on a tab pulls that window out of the group (the virtual pointer); a click on a tab selects it
#   forced    : (0.3.1) a window a rule leaves without a border (border_size = 0) gets the border while it is in a group: tiled, exactly
#               its bordered sibling's size; its border pixel for pixel a bordered member's but for the tab, at scales 1 / 1.25 / 1.5 and
#               over a floating sweep; the click and the drag-out on its band; out of the group the rule is back (no border pixels);
#               grouped and ungrouped over and over; closed while grouped
#   lifecycle : unload with a live group of two (one of them the borderless member: its border given back), then load (forced again)
#               and `hyprctl reload` with the config guard
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export LOCK_ENV="${LOCK_ENV:-nightgroup}"
E="nice -n 19 $ROOT/tools/dev/lock_env.sh"
OUT="${OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/hypr-group-tabs-test}"
SO_GIVEN="${SO:-}"
SO="${SO:-$HERE/hypr-group-tabs.so}"
ARM="${ARM:-}"
FORCE_ONLY="${FORCE_ONLY:-}"
mkdir -p "$OUT"
find "${OUT:?}" -maxdepth 1 -name '*.png' -delete

fails=0; checks=0; failed=""
say() { echo "$@"; }
ck() { # name verdict(0 ok) detail
    checks=$((checks + 1))
    if [ "$2" = 0 ]; then say "CHECK PASS $1: $3"; else say "CHECK FAIL $1: $3"; fails=$((fails + 1)); failed="$failed $1"; fi
}
# the checks an armed build must fail: the fault it carries, seen by the check aimed at it
case "$ARM" in
    force) ARM_MUST="forced_geometry forced_tab_scale1" ;;
    release) ARM_MUST="forced_drag_out forced_ungrouped_no_border" ;;
    "" | 1) ARM_MUST="" ;;
    *) say "GROUPTABS RESULT FAIL (unknown ARM=$ARM: 1, force or release)"; exit 2 ;;
esac
verdict() { # the last line; exit status follows it
    say "CHECKS $checks FAILS $fails"
    [ -z "${KEEP_SHOTS:-}" ] && find "${OUT:?}" -maxdepth 1 \( -name '*.png' -o -name '*.py' -o -name 'hypr-group-tabs-arm-*.so' \) -delete
    if [ "$ARM" = 1 ]; then
        if [ "$fails" -gt 0 ]; then say "GROUPTABS RESULT PASS (ARM: the vanilla bar fails the checks, as it must)"; exit 0; fi
        say "GROUPTABS RESULT FAIL (ARM: nothing failed, the probe cannot see the difference)"; exit 1
    fi
    if [ -n "$ARM" ]; then
        local m missed=""
        for m in $ARM_MUST; do case " $failed " in *" $m "*) ;; *) missed="$missed $m" ;; esac; done
        if [ -z "$missed" ]; then say "GROUPTABS RESULT PASS (ARM=$ARM: $ARM_MUST failed, as they must)"; exit 0; fi
        say "GROUPTABS RESULT FAIL (ARM=$ARM: passed although the build carries the fault:$missed)"; exit 1
    fi
    if [ "$fails" = 0 ]; then say "GROUPTABS RESULT PASS${1:+ ($1)}"; exit 0; fi
    say "GROUPTABS RESULT FAIL"; exit 1
}

if [ -n "$ARM_MUST" ]; then
    # the armed build, beside the shots (never the plugin's own .so)
    FORCE_ONLY=1
    case "$ARM" in force) DEF=GROUP_TABS_ARM_NO_FORCE ;; *) DEF=GROUP_TABS_ARM_NO_RELEASE ;; esac
    SO="$OUT/hypr-group-tabs-arm-$ARM.so"; rm -f "$SO"
    nice -n 19 make -C "$HERE" TARGET="$SO" EXTRA_FLAGS="--no-gnu-unique -D$DEF" "$SO" > /dev/null || { say "GROUPTABS RESULT FAIL (ARM build)"; exit 1; }
fi
# always through make: it rebuilds when the Hyprland headers' hash moved (an existing .so may be for the last Hyprland)
[ -n "${SO_GIVEN:-}" ] || nice -n 19 make -C "$HERE" all > /dev/null || { say "GROUPTABS RESULT FAIL (build)"; exit 1; }

cleanup() { env -u KEEP "$ROOT/tools/dev/lock_env.sh" down > /dev/null 2>&1; }
trap cleanup EXIT
OUTPUTS=2 $E up > /dev/null 2>&1 || { say "GROUPTABS RESULT FAIL (nested Hyprland did not come up)"; exit 1; }
ev() { $E hyprctl eval "$1" > /dev/null; }
dsp() { $E hyprctl dispatch "$1" > /dev/null; }
clients() { $E hyprctl -j clients; }
settle() { sleep "${1:-0.6}"; }
opt() { $E hyprctl -j getoption "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("int", d.get("bool", d.get("float", d.get("custom", d.get("str"))))))'; }
alive() { clients | python3 -c 'import json,sys; sys.exit(0 if len(json.load(sys.stdin))==int(sys.argv[1]) else 1)' "$1" 2> /dev/null; }

GUARD='hl.config({ group = { groupbar = { enabled = (hl.plugin.group_tabs == nil) } } })'
# The window rule of section K, the user's yazi rule in small: a window titled nb has no border. A line of the env's own config file, so
# every reload below (the plugin's load is one) keeps it.
NOBORDER='hl.window_rule({ name = "gt_noborder", match = { title = "^nb$" }, border_size = 0 })'
echo "$NOBORDER" >> "$($ROOT/tools/dev/lock_env.sh dir)/hyprland.lua"
ev "$NOBORDER"
# the plugin first: it reloads the config on load, which would wipe anything set by eval
if [ "$ARM" != 1 ]; then
    ev "$GUARD"; before=$(opt group:groupbar:enabled)
    out=$($E hyprctl plugin load "$SO"); [ "$out" = ok ] || { say "GROUPTABS RESULT FAIL (plugin load: $out)"; exit 1; }
    ev "$GUARD"; after=$(opt group:groupbar:enabled)
    if [ "$before" = True ] && [ "$after" = False ]; then ck lua_guard 0 "groupbar:enabled is $before without the plugin and $after with it (config guard: enabled = (hl.plugin.group_tabs == nil))"
    else ck lua_guard 1 "groupbar:enabled before=$before after=$after (want True then False)"; fi
    ev 'hl.config({ plugin = { group_tabs = { fade = 0.25 } } })'; fd=$(opt plugin:group_tabs:fade)
    if python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - 0.25) < 1e-6 else 1)' "$fd" 2> /dev/null; then ck own_options 0 "plugin:group_tabs:fade settable from Lua ($fd)"; else ck own_options 1 "plugin:group_tabs:fade reads '$fd'"; fi
    ev 'hl.config({ plugin = { group_tabs = { fade = 0.5 } } })'
fi
# --- the user's own geometry (appearance.lua), the colours made loud so pixels can tell them apart. The group's border colours are the plain
# border's, as the user's config will have them (border_locked_active = the active border): a grouped border is then the plain one.
ROUNDING=16
ev "hl.config({ general = { gaps_in = 3, gaps_out = 0, border_size = 3, col = { active_border = \"rgb(598DEF)\", inactive_border = \"rgb(454963)\" } },
  decoration = { rounding = $ROUNDING },
  group = { col = { border_active = \"rgb(598DEF)\", border_inactive = \"rgb(454963)\", border_locked_active = \"rgb(598DEF)\", border_locked_inactive = \"rgb(454963)\" },
    auto_group = false,
    groupbar = { indicator_height = 3, rounding = 1, gaps_in = 6, gaps_out = 3, render_titles = false, round_only_edges = false, keep_upper_gap = false,
      col = { active = \"rgb(FF3030)\", inactive = \"rgb(30D030)\", locked_active = \"rgb(F0AA0B)\", locked_inactive = \"rgb(C838C6)\" } } } })"
if [ "$ARM" != 1 ]; then ev 'hl.config({ group = { groupbar = { enabled = false } } })'; fi
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1 })'

# a kitty titled $1; returns once Hyprland lists one more window of that title (a loaded machine maps it seconds late), then settles
spawn() { local n0 i; n0=$(titled "$1")
          ( $E run kitty --override background=#202020 --override cursor_blink_interval=0 --override confirm_os_window_close=0 --title "$1" sleep 900 > /dev/null 2>&1 & )
          for i in $(seq 1 80); do [ "$(titled "$1")" -gt "$n0" ] && break; sleep 0.25; done; settle 0.6; }
titled() { clients | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin) if c["title"]==sys.argv[1]))' "$1" 2> /dev/null || echo 0; }
geom() { # title -> "x y w h" in logical px
    clients | python3 -c 'import json,sys
t=sys.argv[1]
for c in json.load(sys.stdin):
    if c["title"]==t: print(c["at"][0],c["at"][1],c["size"][0],c["size"][1])' "$1"
}
members() { clients | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c["title"]==sys.argv[1]: print(len(c["grouped"]))' "$1"; }
join() { # window -> into the group beside it, whichever side it is on
    local d; for d in left right up down; do
        dsp "hl.dsp.focus({ window = \"title:$1\" })"; dsp "hl.dsp.window.move({ into_group = \"$d\" })"; settle 0.5
        [ "$(members "$1")" -gt 0 ] 2> /dev/null && return 0
    done; return 1; }
active() { $E hyprctl -j activewindow | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))'; }
shot() { $E shot "$OUT/$1.png" "${2:-}"; }
# a pair of shots of the same frame: the plugin's border, then the vanilla border of the same window (plugin:group_tabs:enabled = false)
pair() { shot "$1" "${2:-LOCK-1}"; ev 'hl.config({ plugin = { group_tabs = { enabled = false } } })'; settle 0.35
         shot "$1_ref" "${2:-LOCK-1}"; ev 'hl.config({ plugin = { group_tabs = { enabled = true } } })'; settle 0.35; }
# The virtual pointer: `abs X Y W H` is a place in a W x H box Hyprland stretches over the whole layout, so W H are the layout's own
# extent (lext: the monitors' bounding box in logical px) and X Y land where they say. pt X Y steps...: in from 3 px left (Hyprland
# re-evaluates what is under the pointer on motion only), then the steps.
lext() { read -r LW LH <<< "$($E hyprctl -j monitors | python3 -c 'import json,sys
m=json.load(sys.stdin); print(int(max(x["x"] + x["width"] / x["scale"] for x in m)), int(max(x["y"] + x["height"] / x["scale"] for x in m)))')"; }
pt() { $E point "abs $(($1 - 3)) $2 $LW $LH" "sleep 80" "abs $1 $2 $LW $LH" "sleep 150" "${@:3}"; }
# the middle of tab i of a group of two on the window at $gx (width $gw): its share of the straight top edge
tabx() { python3 -c 'import sys; x,w,r,n,i=[float(v) for v in sys.argv[1:]]; print(int(x + r + (w - 2*r) * (i + 0.5) / n))' "$gx" "$gw" "$ROUNDING" 2 "$1"; }

# --- the reader: the plugin's shot against the vanilla border's shot of the same window
cat > "$OUT/seg.py" <<'PY'
import sys, json, math
from PIL import Image
# seg.py shot ref scale "x y w h" N idx rounding border borderhex  (window box in logical px of the shot's output)
png, ref, s = sys.argv[1], sys.argv[2], float(sys.argv[3])
ax, ay, aw, ah = [float(v) for v in sys.argv[4].split()]
N, IDX, ROUND, BORDER = int(sys.argv[5]), int(sys.argv[6]), float(sys.argv[7]), int(sys.argv[8])
BCOL = tuple(int(sys.argv[9][i:i + 2], 16) for i in (0, 2, 4))
def r(v): return int(math.floor(v + 0.5))   # C++ std::round for positives
im, rf = Image.open(png).convert("RGB"), Image.open(ref).convert("RGB")
W, H = im.size
# the element's box as the border decoration makes it (scaled, edges rounded), its band, its straight top edge in N shares (the plugin's sums)
ix, iy = r(s * ax), r(s * ay); iw = r(s * (ax + aw)) - ix; ih = r(s * (ay + ah)) - iy
sbs = r(BORDER * s); rd = int(ROUND * s)
spanl, spanw = ix + rd, iw - 2 * rd
x0, x1 = r(spanl + IDX * spanw / N), r(spanl + (IDX + 1) * spanw / N)
# The border's ring and a margin around it, the window's surface left out (its client draws what it likes between two shots): everything the
# border, the plugin, or a strip laid beside the border could touch.
M = sbs + 4
diff = [(x, y) for y in range(max(0, iy - M), min(H, iy + ih + M)) for x in range(max(0, ix - M), min(W, ix + iw + M))
        if not (ix <= x < ix + iw and iy <= y < iy + ih) and im.getpixel((x, y)) != rf.getpixel((x, y))]
xm = (x0 + x1) // 2
def dist(p, q): return max(abs(a - b) for a, b in zip(p, q))
bandrows = [y for y in range(max(0, iy - M), iy + 3) if dist(rf.getpixel((xm, y)), BCOL) <= 12]
out = {
    "seg": [x0, x1], "band": [iy - sbs, iy], "bandrows_ref": bandrows,
    "diff_n": len(diff),
    "diff_x": [min(x for x, _ in diff), max(x for x, _ in diff)] if diff else None,
    "diff_y": sorted(set(y for _, y in diff)),
    "mid_rows_differ": all(im.getpixel((xm, y)) != rf.getpixel((xm, y)) for y in range(iy - sbs, iy)),
    # the tab is drawn on the border's rows as one colour per column: a row of another colour (the window, the gap, the plain border)
    # under or over it is what a tab a row off the border looks like
    "rows_uniform": all(max(dist(im.getpixel((x, y)), im.getpixel((x, iy - 1))) for y in range(iy - sbs, iy)) <= 3 for x in range(x0, x1)),
    "rows_odd": [x for x in range(x0, x1) if max(dist(im.getpixel((x, y)), im.getpixel((x, iy - 1))) for y in range(iy - sbs, iy)) > 3][:4],
    "mid": [list(im.getpixel((xm, y))) for y in range(iy - sbs, iy)],
    "end_l": list(im.getpixel((x0, iy - 1))), "end_r": list(im.getpixel((x1 - 1, iy - 1))),
    "step_l": dist(im.getpixel((x0, iy - 1)), im.getpixel((x0 - 1, iy - 1))),
    "step_r": dist(im.getpixel((x1 - 1, iy - 1)), im.getpixel((x1, iy - 1))),
}
print(json.dumps(out))
PY
seg() { python3 "$OUT/seg.py" "$@"; }
jget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2], {}, d))' "$1" "$2"; }
near() { python3 -c 'import sys,json; a=json.loads(sys.argv[1]); b=[int(sys.argv[2][i:i+2],16) for i in (0,2,4)]; sys.exit(0 if max(abs(x-y) for x,y in zip(a,b)) <= int(sys.argv[3]) else 1)' "$1" "$2" "${3:-10}"; }

# check_seg name shot scale "x y w h" N idx tabhex [bordhex]: the identity, and the colour the segment's middle reaches
check_seg() {
    local r; r=$(seg "$OUT/$2.png" "$OUT/$2_ref.png" "$3" "$4" "$5" "$6" "$ROUNDING" 3 "${8:-598DEF}")
    local x0 x1 dx dy bt bb ok=0 why=""
    x0=$(jget "$r" 'seg[0]'); x1=$(jget "$r" 'seg[1]'); bt=$(jget "$r" 'band[0]'); bb=$(jget "$r" 'band[1]')
    dx=$(jget "$r" 'diff_x'); dy=$(jget "$r" 'diff_y')
    # every differing pixel of the border's ring inside the segment's columns and the band's rows
    if [ "$(jget "$r" 'diff_n')" = 0 ]; then ok=1; why="$why nothing differs from the vanilla border"
    else
        jget "$r" "diff_x[0] >= $x0 and diff_x[1] < $x1 and min(diff_y) >= $bt and max(diff_y) < $bb" | grep -qx True || { ok=1; why="$why differences at x=$dx rows $dy outside the segment [$x0,$x1) x [$bt,$bb)"; }
    fi
    [ "$(jget "$r" 'bandrows_ref')" = "$(python3 -c "print(list(range($bt,$bb)))")" ] || { ok=1; why="$why vanilla band rows $(jget "$r" 'bandrows_ref') != [$bt,$bb)"; }
    [ "$(jget "$r" 'mid_rows_differ')" = True ] || { ok=1; why="$why not every band row of the segment's middle is the tab's"; }
    [ "$(jget "$r" 'rows_uniform')" = True ] || { ok=1; why="$why band rows of another colour at columns $(jget "$r" 'rows_odd')"; }
    local m; for m in 0 $(( $(jget "$r" 'len(mid)') - 1 )); do near "$(jget "$r" "mid[$m]")" "$7" 12 || { ok=1; why="$why middle row $m $(jget "$r" "mid[$m]") is not the tab colour #$7"; }; done
    if [ -n "${8:-}" ]; then
        near "$(jget "$r" 'end_l')" "$8" 6 && near "$(jget "$r" 'end_r')" "$8" 6 || { ok=1; why="$why ends $(jget "$r" 'end_l') / $(jget "$r" 'end_r') are not the border #$8"; }
        [ "$(jget "$r" 'step_l <= 4 and step_r <= 4')" = True ] || { ok=1; why="$why a step where the segment meets the border ($(jget "$r" 'step_l') / $(jget "$r" 'step_r') levels)"; }
    fi
    ck "$1" $ok "segment [$x0,$x1) rows [$bt,$bb): differences x=$dx rows=$dy, middle $(jget "$r" 'mid[len(mid)//2]')$why"
}

# the cursor is never drawn (a cursor over a border would be a difference of its own); the pointer still moves and clicks
ev 'hl.config({ cursor = { invisible = true } })'

if [ -z "$FORCE_ONLY" ]; then
# --- A. one window alone: the reference geometry
spawn w1
G0=$(geom w1)
say "ungrouped w1 alone: at/size = $G0"

# --- B. two windows in one group
spawn w2
dsp 'hl.dsp.focus({ window = "title:w1" })'; dsp 'hl.dsp.group.toggle()'; settle
join w2; settle 0.5
dsp 'hl.dsp.focus({ window = "title:w1" })'; settle
n=$(members w1)
if [ "$n" = 2 ]; then ck group_formed 0 "group of $n"; else ck group_formed 1 "group of $n (expected 2)"; fi
G1=$(geom w1)
if [ "$G1" = "$G0" ]; then ck geometry_grouped_equals_ungrouped 0 "grouped $G1 == ungrouped $G0"
else ck geometry_grouped_equals_ungrouped 1 "grouped $G1 != ungrouped $G0 (height shrinks by $(( ${G0##* } - ${G1##* } )) px)"; fi

if [ "$ARM" = 1 ]; then
    say "ARM: plugin NOT loaded, vanilla groupbar enabled"
    verdict
fi

# member order: w1 then w2 (w2 was moved in on w1's left? read it rather than assume)
IDX1=$(clients | python3 -c 'import json,sys
cs=json.load(sys.stdin); a={c["address"]:c["title"] for c in cs}
g=[c for c in cs if c["title"]=="w1"][0]["grouped"]; print([a[x] for x in g].index("w1"))')
IDX2=$((1 - IDX1))
say "group order: w1 is tab $IDX1"

# --- C. the identity at scale 1, the focused member's tab
pair b1
check_seg seg_scale1 b1 1 "$G1" 2 "$IDX1" FF3030 598DEF

# --- D. the other tab: the segment follows the focus
dsp 'hl.dsp.focus({ window = "title:w2" })'; settle 0.8
pair d1
check_seg seg_follows_focus d1 1 "$G1" 2 "$IDX2" FF3030 598DEF

# --- the fade option: 0 is a flat tab (the tab colour to its ends: there it does differ in a step, as asked)
ev 'hl.config({ plugin = { group_tabs = { fade = 0 } } })'; settle 0.4; pair k1
r=$(seg "$OUT/k1.png" "$OUT/k1_ref.png" 1 "$G1" 2 "$IDX2" "$ROUNDING" 3 598DEF)
if near "$(jget "$r" 'end_l')" FF3030 12 && near "$(jget "$r" 'end_r')" FF3030 12; then ck look_fade_off 0 "fade 0: the tab colour to both ends ($(jget "$r" 'end_l') / $(jget "$r" 'end_r'))"
else ck look_fade_off 1 "fade 0: ends $(jget "$r" 'end_l') / $(jget "$r" 'end_r') (want #FF3030)"; fi
ev 'hl.config({ plugin = { group_tabs = { fade = 0.5 } } })'; settle 0.4

# --- the scale 1.25 (the user's)
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1.25 })'; settle 1.2
G125=$(geom w2); say "scale 1.25: grouped w2 at/size = $G125 (logical)"
pair c1
check_seg seg_scale125 c1 1.25 "$G125" 2 "$IDX2" FF3030 598DEF
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1 })'; settle 1

# --- the unfocused group (the focus on another window) shows its current tab in col.inactive, and fades there on the border's own clock
spawn w3
settle 0.4
GU=$(geom w2)
pair u1
check_seg seg_unfocused u1 1 "$GU" 2 "$IDX2" 30D030 454963

# --- locked (lockactivegroup): col.locked_active
dsp 'hl.dsp.focus({ window = "title:w2" })'; settle 0.6
dsp 'hl.dsp.group.lock()'; settle 0.8
GL=$(geom w2)
pair l1
check_seg seg_locked l1 1 "$GL" 2 "$IDX2" F0AA0B 598DEF
dsp 'hl.dsp.group.lock()'; settle 0.6

# --- the tab colour fades on the border's own clock: animations on for this part, the border's fade slowed to 8 s and linear; the focus goes
# to w3, so the group's border fades from the active colour to the inactive one and its tab from col.active to col.inactive, by the same
# share at every moment
ev 'hl.curve("gtlin", { type = "bezier", points = { {0, 0}, {1, 1} } })'
ev 'hl.config({ animations = { enabled = true } })'
ev 'hl.animation({ leaf = "border", enabled = true, speed = 80, bezier = "gtlin" })'
dsp 'hl.dsp.focus({ window = "title:w3" })'; sleep 3.5
shot f1 LOCK-1
ev 'hl.config({ animations = { enabled = false } })'; settle 1
GF=$(geom w2)
r=$(python3 - "$OUT/f1.png" "$GF" "$IDX2" "$ROUNDING" <<'PY'
import sys, math
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); ax, ay, aw, ah = [float(v) for v in sys.argv[2].split()]; idx, R = int(sys.argv[3]), float(sys.argv[4])
def ok(c):
    def lin(v): v /= 255.0; return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3); m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
def frac(c, a, b):   # where c stands on the way from a to b (OkLab, projected)
    c, a, b = ok(c), ok(a), ok(b); d = [y - x for x, y in zip(a, b)]
    return sum((z - x) * e for z, x, e in zip(c, a, d)) / sum(e * e for e in d)
x0 = int(ax + R); w = aw - 2 * R
xt = int(x0 + w * (idx + 0.5) / 2); xb = int(x0 + w * (1 - idx + 0.5) / 2); y = int(ay) - 1
tb = frac(im.getpixel((xb, y)), (0x59, 0x8D, 0xEF), (0x45, 0x49, 0x63)); tt = frac(im.getpixel((xt, y)), (0xFF, 0x30, 0x30), (0x30, 0xD0, 0x30))
print("%.3f %.3f %s %s" % (tb, tt, im.getpixel((xb, y)), im.getpixel((xt, y))))
PY
)
read -r tb tt _ <<< "$r"
if python3 -c 'import sys; b, t = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if 0.1 < b < 0.9 and abs(b - t) < 0.12 else 1)' "$tb" "$tt"; then
    ck fade_on_border_clock 0 "mid-fade the border is $tb of the way to the inactive colour and the tab $tt of the way to col.inactive ($r)"
else ck fade_on_border_clock 1 "border $tb, tab $tt of the way (want both strictly between and within 0.12 of each other): $r"; fi
dsp 'hl.dsp.focus({ window = "title:w2" })'; settle 0.6

# --- a group of four: the selected tab is a quarter of the straight edge
join w3; settle 0.5
ev 'hl.config({ group = { auto_group = true } })'; dsp 'hl.dsp.focus({ window = "title:w3" })'; settle 0.4
spawn w4
ev 'hl.config({ group = { auto_group = false } })'
dsp 'hl.dsp.focus({ window = "title:w4" })'; settle 0.6
G4=$(geom w4); n4=$(members w4)
IDX4=$(clients | python3 -c 'import json,sys
cs=json.load(sys.stdin); a={c["address"]:c["title"] for c in cs}
g=[c for c in cs if c["title"]=="w4"][0]["grouped"]; print([a[x] for x in g].index("w4"))')
pair q1
if [ "$n4" = 4 ]; then check_seg seg_group_of_four q1 1 "$G4" 4 "$IDX4" FF3030 598DEF; else ck seg_group_of_four 1 "group of $n4 (want 4)"; fi

# --- E. fullscreen: no border, no tab, nothing on the top rows
dsp 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'; settle 0.8
shot e1 LOCK-1
t=$(python3 -c 'import sys; from PIL import Image
im=Image.open(sys.argv[1]).convert("RGB"); tabs=[(255,48,48),(48,208,48),(240,170,11),(200,56,198),(89,140,238)]
print(sum(1 for x in range(0,2880) for y in range(0,4) if any(max(abs(a-b) for a,b in zip(im.getpixel((x,y)),t)) <= 30 for t in tabs)))' "$OUT/e1.png")
if [ "$t" = 0 ]; then ck fullscreen_no_tabs 0 "no tab or border pixels in the top 4 rows"; else ck fullscreen_no_tabs 1 "$t tab- or border-coloured pixels"; fi
dsp 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'; settle 0.8
G3=$(geom w4)
if [ "$G3" = "$G0" ]; then ck fullscreen_roundtrip 0 "geometry back to $G3"; else ck fullscreen_roundtrip 1 "$G3 != $G0"; fi
# back to a group of two (w1, w2) for the rest
for w in w3 w4; do dsp "hl.dsp.window.close({ window = \"title:$w\" })"; settle 0.8; done
dsp 'hl.dsp.focus({ window = "title:w2" })'; settle 0.6
[ "$(members w2)" = 2 ] || say "NOTE: after closing w3 and w4 the group has $(members w2) members"

# --- F + J. floating, and the grid sweep: the identity at every fractional position the window can stand at, at 1, 1.25 and 1.5. At 1.25 and 1.5
# the window's edge and the border's width are rounded separately; a tab drawn beside the border (0.1 / 0.2) stood a row off at some of these.
dsp 'hl.dsp.window.float({ action = "toggle" })'; settle 0.8
dsp 'hl.dsp.window.resize({ x = 1400, y = 900, exact = true })'; dsp 'hl.dsp.window.move({ x = 500, y = 300 })'; settle 0.8
NOW=$(members w2); IDXF=$(clients | python3 -c 'import json,sys
cs=json.load(sys.stdin); a={c["address"]:c["title"] for c in cs}
g=[c for c in cs if c["title"]=="w2"][0]["grouped"]; print([a[x] for x in g].index("w2"))')
for SC in 1 1.25 1.5; do
    ev "hl.monitor({ output = \"LOCK-1\", mode = \"2880x1620@60\", position = \"0x0\", scale = $SC })"; settle 1.2
    n=8; [ "$SC" = 1.5 ] && n=4; [ "$SC" = 1 ] && n=2
    bad=""
    for k in $(seq 0 $((n - 1))); do
        dsp "hl.dsp.window.move({ x = $((500 + 3 * k)), y = $((300 + k)) })"; settle 0.45
        GK=$(geom w2); pair j1
        r=$(seg "$OUT/j1.png" "$OUT/j1_ref.png" "$SC" "$GK" "$NOW" "$IDXF" "$ROUNDING" 3 598DEF)
        x0=$(jget "$r" 'seg[0]'); x1=$(jget "$r" 'seg[1]'); bt=$(jget "$r" 'band[0]'); bb=$(jget "$r" 'band[1]')
        res=$(jget "$r" "diff_n > 0 and diff_x[0] >= $x0 and diff_x[1] < $x1 and min(diff_y) >= $bt and max(diff_y) < $bb and mid_rows_differ and rows_uniform and bandrows_ref == list(range($bt, $bb))")
        [ "$res" = True ] || bad="$bad [at $GK: seg [$x0,$x1) band [$bt,$bb) diff x=$(jget "$r" 'diff_x') rows=$(jget "$r" 'diff_y') ref rows=$(jget "$r" 'bandrows_ref') mid_rows=$(jget "$r" 'mid_rows_differ') odd rows at x=$(jget "$r" 'rows_odd')]"
    done
    if [ -z "$bad" ]; then ck "band_sweep_$SC" 0 "$n positions at scale $SC: only the segment's band rows differ from the vanilla border, all of them, one colour per column"
    else ck "band_sweep_$SC" 1 "$bad"; fi
done
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1 })'; settle 1
[ -n "${SWEEP_ONLY:-}" ] && verdict "sweep only"
dsp 'hl.dsp.window.float({ action = "toggle" })'; settle 0.8

# --- input: a click on the other tab selects it (no bind on the button: the click reaches the decoration)
lext
G2=$(geom w2); read -r gx gy gw gh <<< "$G2"
before=$(active)
pt "$(tabx "$IDX1")" $((gy - 2)) click; settle 0.8
after=$(active)
if [ "$before" = w2 ] && [ "$after" = w1 ]; then ck click_selects_tab 0 "a click on tab $IDX1 of the band selected it ($before -> $after)"
else ck click_selects_tab 1 "active $before -> $after (want w2 -> w1)"; fi

# --- input: the move bind off the tabs (on the band, in the corner arc) moves the whole group: nothing leaves it. The bind is the user's
# `hl.dsp.window.drag()` mouse bind, here on the bare button (a held modifier is the keybind manager's business, not the plugin's).
ev 'hl.bind("mouse:272", hl.dsp.window.drag(), { mouse = true })'
pt $((gx + 4)) $((gy - 2)) down "sleep 120" "abs $((gx + 300)) 400 5760 1620" "sleep 250" up
settle 1
m2=$(members w2)
if [ "$m2" = 2 ]; then ck drag_off_tabs 0 "the move bind on the corner, off the tabs, leaves the group whole ($m2)"; else ck drag_off_tabs 1 "group of $m2 after a drag on the corner (want 2)"; fi

# --- input: the move bind pressed on a tab pulls THAT window out of the group (here the hidden member's tab); dropped on the other output it
# stays out, as on the vanilla groupbar
G2=$(geom w1); read -r gx gy gw gh <<< "$G2"
pt "$(tabx "$IDX2")" $((gy - 2)) down "sleep 120" "abs 2600 400 $LW $LH" "sleep 100" "abs 3600 800 $LW $LH" "sleep 100" "abs 4300 800 $LW $LH" "sleep 250" up
settle 1.2
m1=$(members w1); m2=$(members w2); ws2=$(clients | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c["title"]=="w2": print(c["workspace"]["name"], c["monitor"])')
if [ "$m1" = 1 ] && [ "$m2" = 0 ] && [ "${ws2%% *}" != 1 ]; then ck drag_out 0 "the move bind on tab $IDX2 pulled w2 out of the group and dropped it on the other output (w1 group of $m1, w2 grouped $m2, w2 on workspace/monitor $ws2)"
else ck drag_out 1 "w1 group of $m1, w2 grouped $m2, w2 on $ws2 (want 1 / 0 / not workspace 1)"; fi
ev 'hl.unbind("mouse:272")'

# --- G. group of one (the vanilla bar shows a single tab too): the whole straight edge is the tab
dsp 'hl.dsp.focus({ window = "title:w1" })'; settle 0.8
n1=$(members w1); say "after w2 left the group: w1's group has $n1 member(s)"
GW1=$(geom w1)
pair g1
check_seg seg_group_of_one g1 1 "$GW1" 1 0 FF3030 598DEF

# --- H. the workspace on the second output (at 2880,0)
dsp 'hl.dsp.workspace.move({ monitor = "LOCK-2" })'; settle 1.2
GH=$(geom w1); HX=$(python3 -c 'import sys; a=sys.argv[1].split(); print(int(a[0])-2880, a[1], a[2], a[3])' "$GH")
pair h1 LOCK-2
check_seg seg_second_output h1 1 "$HX" 1 0 FF3030 598DEF

fi # FORCE_ONLY

# --- K. a window a rule leaves without a border (border_size = 0: the user's yazi) in a group. While it is grouped the plugin gives it the
# border (general:border_size), so its tab can be seen and used; out of the group the rule is back. Tiled, the forced border makes it
# exactly the size of its bordered sibling (the members share the group's box and each takes off its own border); floating, the box is the
# group's and the border is drawn outside it, as on every floating window.
lext
bsz() { $E hyprctl getprop "title:$1" border_size; }
grown() { python3 -c 'import sys; x,y,w,h=map(int,sys.argv[1].split()); d=int(sys.argv[2]); print(x-d,y-d,w+2*d,h+2*d)' "$1" "$2"; }
idxof() { clients | python3 -c 'import json,sys
cs=json.load(sys.stdin); a={c["address"]:c["title"] for c in cs}
g=[c for c in cs if c["title"]==sys.argv[1]][0]["grouped"]; print([a[x] for x in g].index(sys.argv[1]))' "$1"; }
# A pair for the forced border: nb shown, then the reference: wb shown at the same group box with the plugin off -- the vanilla border of a
# bordered member there, which nb's border must be pixel for pixel but for the tab.
pairg() { shot "$1" "${2:-LOCK-1}"
          dsp 'hl.dsp.focus({ window = "title:wb" })'; ev 'hl.config({ plugin = { group_tabs = { enabled = false } } })'; settle 0.6
          shot "$1_ref" "${2:-LOCK-1}"
          ev 'hl.config({ plugin = { group_tabs = { enabled = true } } })'; dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.6; }
# border-coloured pixels on the ring a border of `b` px would take around the box "x y w h" (logical, on an output at scale 1 at ox); the
# output's outer 8 px are left out, where a tiled window under it (the full run's w1 on LOCK-2) has its own border
ringhits() { python3 - "$OUT/$1.png" "$2" "$3" "$4" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); x, y, w, h = map(int, sys.argv[2].split()); ox, b = int(sys.argv[3]), int(sys.argv[4])
x -= ox
cols = [(0x59, 0x8D, 0xEF), (0x45, 0x49, 0x63)]
W, H = im.size
hit = inside = 0
for yy in range(max(0, y - b), min(H, y + h + b)):
    for xx in range(max(0, x - b), min(W, x + w + b)):
        p = im.getpixel((xx, yy))
        if xx < 8 or yy < 8 or xx >= W - 8 or yy >= H - 8:
            continue
        if x <= xx < x + w and y <= yy < y + h:
            inside += max(abs(a - c) for a, c in zip(p, (0x20, 0x20, 0x20))) <= 8
        elif any(max(abs(a - c) for a, c in zip(p, col)) <= 12 for col in cols):
            hit += 1
print(hit, inside)
PY
}

dsp 'hl.dsp.focus({ monitor = "LOCK-1" })'; dsp 'hl.dsp.focus({ workspace = 6 })'; settle
spawn nb
GNB0=$(geom nb); B0=$(bsz nb)
GBOR=$(grown "$GNB0" -3) # a window with the border, alone on the same workspace
if [ "$B0" = 0 ]; then ck forced_rule_borderless 0 "ungrouped, the rule leaves nb without a border (border_size $B0, at/size $GNB0)"
else ck forced_rule_borderless 1 "nb's border_size reads '$B0' before any group: the rule did not apply, the checks below prove nothing"; fi
spawn wb
dsp 'hl.dsp.focus({ window = "title:nb" })'; dsp 'hl.dsp.group.toggle()'; settle
join wb; settle 0.5
dsp 'hl.dsp.focus({ window = "title:nb" })'; settle
GNB=$(geom nb); GWB=$(geom wb); BNB=$(bsz nb)
if [ "$(members nb)" = 2 ] && [ "$GNB" = "$GBOR" ] && [ "$GWB" = "$GBOR" ] && [ "$BNB" = 3 ]; then
    ck forced_geometry 0 "grouped, nb has the border (border_size $BNB) and its bordered sibling's size: nb $GNB == wb $GWB == a bordered window alone"
else ck forced_geometry 1 "group of $(members nb); nb $GNB border_size $BNB, wb $GWB (want both $GBOR, border_size 3)"; fi
IDXNB=$(idxof nb); IDXWB=$(idxof wb)
dsp 'hl.dsp.focus({ window = "title:wb" })'; settle 0.4; BH=$(bsz nb)
dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.4
if [ "$BH" = 3 ]; then ck forced_while_hidden 0 "nb keeps the border while another member is shown (border_size $BH)"
else ck forced_while_hidden 1 "nb's border_size $BH while wb is shown (want 3)"; fi

pairg k1
check_seg forced_tab_scale1 k1 1 "$GNB" 2 "$IDXNB" FF3030 598DEF
for SC in 1.25 1.5; do
    ev "hl.monitor({ output = \"LOCK-1\", mode = \"2880x1620@60\", position = \"0x0\", scale = $SC })"; settle 1.2
    GK=$(geom nb); pairg k2
    check_seg "forced_tab_scale$SC" k2 "$SC" "$GK" 2 "$IDXNB" FF3030 598DEF
done
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1 })'; settle 1

# Maximized and fullscreen, with the user's own `fullscreen = true` rule (border_size 0, rounding 0), which Hyprland matches for a
# maximized window too: grouped and maximized, the border is forced over it (square corners) and the tab shows; real fullscreen draws no
# border and no tab whatever the property says, and coming back the window has its grouped size again.
# tabrows shot y0 y1 tab|any: pixels of the tab colour (tab), or of any tab or border colour (any), in rows [y0, y1)
tabrows() { python3 -c 'import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); y0, y1 = int(sys.argv[2]), int(sys.argv[3])
cols = [(255, 48, 48)] if sys.argv[4] == "tab" else [(255, 48, 48), (48, 208, 48), (240, 170, 11), (200, 56, 198), (89, 140, 238)]
print(sum(1 for y in range(max(0, y0), y1) for x in range(im.width) if any(max(abs(a - b) for a, b in zip(im.getpixel((x, y)), c)) <= 30 for c in cols)))' "$OUT/$1.png" "$2" "$3" "$4"; }
ev 'hl.window_rule({ name = "gt_fs", match = { fullscreen = true }, border_size = 0, rounding = 0 })'
dsp 'hl.dsp.window.fullscreen({ mode = "maximized" })'; settle 0.8
GM=$(geom nb); BM=$(bsz nb); shot m1 LOCK-1; read -r _ gmy _ _ <<< "$GM"; TM=$(tabrows m1 $((gmy - 3)) "$gmy" tab)
if [ "$BM" = 3 ] && [ "$GM" = "$GBOR" ] && [ "$TM" -gt 100 ]; then ck forced_maximized 0 "maximized under a fullscreen no-border rule: border_size $BM, at $GM, $TM tab-coloured pixels on the band"
else ck forced_maximized 1 "maximized: border_size $BM at $GM (want 3 at $GBOR), $TM tab-coloured pixels on the band (want > 100)"; fi
dsp 'hl.dsp.window.fullscreen({ mode = "maximized" })'; settle 0.8
dsp 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'; settle 0.8
shot f2 LOCK-1; TF=$(tabrows f2 0 4 any)
dsp 'hl.dsp.window.fullscreen({ mode = "fullscreen" })'; settle 0.8
GF=$(geom nb); BF=$(bsz nb)
if [ "$TF" = 0 ] && [ "$GF" = "$GBOR" ] && [ "$BF" = 3 ]; then ck forced_fullscreen 0 "fullscreen: no tab or border pixel in the top 4 rows; back: nb at $GF, border_size $BF"
else ck forced_fullscreen 1 "fullscreen: $TF tab- or border-coloured pixels in the top 4 rows (want 0); back: nb at $GF border_size $BF (want $GBOR, 3)"; fi

# floating, as the user's yazi: the same identity over fractional positions at 1, 1.25 and 1.5, and the members share the group's box
dsp 'hl.dsp.window.float({ action = "toggle" })'; settle 0.8
dsp 'hl.dsp.window.resize({ x = 1400, y = 900, exact = true })'; dsp 'hl.dsp.window.move({ x = 500, y = 300 })'; settle 0.8
for SC in 1 1.25 1.5; do
    ev "hl.monitor({ output = \"LOCK-1\", mode = \"2880x1620@60\", position = \"0x0\", scale = $SC })"; settle 1.2
    n=4; [ "$SC" = 1 ] && n=2
    bad=""
    for k in $(seq 0 $((n - 1))); do
        dsp "hl.dsp.window.move({ x = $((500 + 3 * k)), y = $((300 + k)) })"; settle 0.45
        GK=$(geom nb); GW=$(geom wb); pairg j2
        r=$(seg "$OUT/j2.png" "$OUT/j2_ref.png" "$SC" "$GK" 2 "$IDXNB" "$ROUNDING" 3 598DEF)
        x0=$(jget "$r" 'seg[0]'); x1=$(jget "$r" 'seg[1]'); bt=$(jget "$r" 'band[0]'); bb=$(jget "$r" 'band[1]')
        res=$(jget "$r" "diff_n > 0 and diff_x[0] >= $x0 and diff_x[1] < $x1 and min(diff_y) >= $bt and max(diff_y) < $bb and mid_rows_differ and rows_uniform and bandrows_ref == list(range($bt, $bb))")
        [ "$res" = True ] && [ "$GK" = "$GW" ] || bad="$bad [nb at $GK, wb at $GW: seg [$x0,$x1) band [$bt,$bb) diff x=$(jget "$r" 'diff_x') rows=$(jget "$r" '(diff_y[:6], len(diff_y))') ref rows=$(jget "$r" 'bandrows_ref') mid_rows=$(jget "$r" 'mid_rows_differ') odd rows at x=$(jget "$r" 'rows_odd')]"
    done
    if [ -z "$bad" ]; then ck "forced_sweep_$SC" 0 "$n floating positions at scale $SC: nb's border is wb's but for the tab's band rows, nb and wb share the box"
    else ck "forced_sweep_$SC" 1 "$bad"; fi
done
ev 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1 })'; settle 1
lext

# input on the forced band: a click on wb's tab shows wb
read -r gx gy gw gh <<< "$(geom nb)"
before=$(active)
pt "$(tabx "$IDXWB")" $((gy - 2)) click; settle 0.8
after=$(active)
if [ "$before" = nb ] && [ "$after" = wb ]; then ck forced_click 0 "a click on tab $IDXWB of nb's forced band showed wb ($before -> $after)"
else ck forced_click 1 "active $before -> $after (want nb -> wb)"; fi
dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.6

# the move bind on nb's own tab pulls nb out of the group; dropped on the other output it is out of the group and the rule is back
ev 'hl.bind("mouse:272", hl.dsp.window.drag(), { mouse = true })'
read -r gx gy gw gh <<< "$(geom nb)"
pt "$(tabx "$IDXNB")" $((gy - 2)) down "sleep 120" "abs 2600 400 $LW $LH" "sleep 100" "abs 3600 300 $LW $LH" "sleep 100" "abs 4000 300 $LW $LH" "sleep 250" up
settle 1.2
ev 'hl.unbind("mouse:272")'
mnb=$(members nb); mwb=$(members wb); BNB=$(bsz nb); GO=$(geom nb)
if [ "$mnb" = 0 ] && [ "$mwb" = 1 ] && [ "$BNB" = 0 ]; then ck forced_drag_out 0 "the move bind on nb's tab pulled it out (nb grouped $mnb, wb group of $mwb) and its border went back to the rule (border_size $BNB)"
else ck forced_drag_out 1 "nb grouped $mnb border_size $BNB, wb group of $mwb (want 0 / 0 / 1)"; fi
# ungrouped, no border: nb floats on LOCK-2 (at 2880,0), focused; no pixel of a border colour on the ring a border would take
dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.6; GO=$(geom nb)
shot o1 LOCK-2
read -r hit inside <<< "$(ringhits o1 "$GO" 2880 3)"
if [ "$hit" = 0 ] && [ "$inside" -gt 1000 ]; then ck forced_ungrouped_no_border 0 "ungrouped nb at $GO: no border-coloured pixel on its ring ($inside window pixels seen inside)"
else ck forced_ungrouped_no_border 1 "ungrouped nb at $GO: $hit border-coloured pixels on its ring, $inside window pixels inside (want 0 and > 1000)"; fi

# grouped and ungrouped over and over, tiled: joined into wb's group and moved out again, toggled into a group of one and out
dsp 'hl.dsp.window.move({ workspace = "6", window = "title:nb" })'; settle 0.8
dsp 'hl.dsp.focus({ monitor = "LOCK-1" })'; dsp 'hl.dsp.focus({ workspace = 6 })'; settle 0.4
for w in nb wb; do dsp "hl.dsp.focus({ window = \"title:$w\" })"; dsp 'hl.dsp.window.float({ action = "toggle" })'; settle 0.6; done
bad=""
for i in 1 2 3 4 5; do
    if join nb; then
        settle 0.3
        [ "$(bsz nb)" = 3 ] && [ "$(geom nb)" = "$(geom wb)" ] || bad="$bad [cycle $i joined: nb $(geom nb) border $(bsz nb), wb $(geom wb)]"
        dsp 'hl.dsp.window.move({ out_of_group = true, window = "title:nb" })'; settle 0.5
        [ "$(bsz nb)" = 0 ] && [ "$(members nb)" = 0 ] || bad="$bad [cycle $i out: nb grouped $(members nb) border $(bsz nb)]"
    else bad="$bad [cycle $i: nb did not join]"; fi
    dsp 'hl.dsp.focus({ window = "title:nb" })'; dsp 'hl.dsp.group.toggle()'; settle 0.4
    [ "$(bsz nb)" = 3 ] && [ "$(members nb)" = 1 ] || bad="$bad [cycle $i toggled in: nb grouped $(members nb) border $(bsz nb)]"
    dsp 'hl.dsp.group.toggle()'; settle 0.4
    [ "$(bsz nb)" = 0 ] && [ "$(members nb)" = 0 ] || bad="$bad [cycle $i toggled out: nb grouped $(members nb) border $(bsz nb)]"
done
if [ -z "$bad" ] && alive "$(clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"; then
    ck forced_cycles 0 "5 x (joined, moved out, toggled in, toggled out): the border on every time it is grouped, off every time it is not"
else ck forced_cycles 1 "$bad"; fi

# closed while grouped (and shown)
join nb; settle 0.4; dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.4
NCL=$(clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'); mj=$(members nb)
dsp 'hl.dsp.window.close({ window = "title:nb" })'; settle 1
GWC=$(geom wb)
if [ "$mj" = 2 ] && alive $((NCL - 1)) && [ "$(members wb)" = 1 ] && [ "$GWC" = "$GBOR" ]; then ck forced_close 0 "nb closed while grouped and shown: compositor alive, wb a group of one at $GWC"
else ck forced_close 1 "nb grouped $mj before; after the close: $(clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') of $((NCL - 1)) windows, wb group of $(members wb) at $GWC (want $GBOR)"; fi

# a new nb in wb's group for the unload
spawn nb; join nb; settle 0.4; dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.4

# --- I. unload and load again with live groups: [wb, nb] on LOCK-1 with the borderless nb shown, and in the full run [w1, w2] on LOCK-2.
# Hyprland runs PLUGIN_EXIT before it removes the plugin's decorations, and each removal repositions the group and calls the other member's
# decoration: state freed in PLUGIN_EXIT must not be read there. PLUGIN_EXIT gives every forced border back.
if [ -z "$FORCE_ONLY" ]; then
dsp 'hl.dsp.focus({ window = "title:w1" })'; settle 0.4
WS1=$(clients | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c["title"]=="w1": print(c["workspace"]["name"])')
dsp "hl.dsp.window.move({ workspace = \"$WS1\", window = \"title:w2\" })"; settle 0.8
join w2; settle 0.6
if [ "$(members w2)" = 2 ]; then ck unload_group_of_two 0 "two windows are grouped at the unload"
else ck unload_group_of_two 1 "no group of two at the unload: the check below proves nothing"; fi
fi
dsp 'hl.dsp.focus({ window = "title:nb" })'; settle 0.5
if [ "$(members nb)" = 2 ] && [ "$(bsz nb)" = 3 ] && [ "$(active)" = nb ]; then ck unload_borderless_member 0 "[wb, nb] grouped at the unload, nb shown with its forced border"
else ck unload_borderless_member 1 "nb grouped $(members nb), border_size $(bsz nb), active $(active): the checks below prove less"; fi
NC=$(clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
out=$($E hyprctl plugin unload "$SO"); settle 0.8
if alive "$NC"; then ck unload_survives 0 "plugin unload: '$out', compositor and all $NC windows alive"; else ck unload_survives 1 "plugin unload: '$out', compositor or windows gone"; fi
# the unload gave nb's border back: the rule's 0, and nb a border wider than wb's on every side (wb takes off the config's border)
BU=$(bsz nb); GU=$(geom nb); BG=$(opt general:border_size); GUW=$(geom wb)
if [ "$BU" = 0 ] && [ "$GU" = "$(grown "$GUW" "$BG")" ]; then ck unload_gives_back 0 "after the unload nb's border_size is $BU and nb $GU is wb $GUW grown by the config's border $BG"
else ck unload_gives_back 1 "after the unload nb border_size $BU at $GU, wb $GUW, general border $BG (want 0, wb grown by $BG)"; fi
# the guard as a CONFIG FILE line (the nested env's private hyprland.lua), through a real reload
echo 'hl.config({ group = { groupbar = { enabled = (hl.plugin.group_tabs == nil) } } })' >> "$($ROOT/tools/dev/lock_env.sh dir)/hyprland.lua"
$E hyprctl reload > /dev/null; settle 1
g_off=$(opt group:groupbar:enabled)
out=$($E hyprctl plugin load "$SO"); settle 0.8
$E hyprctl reload > /dev/null; settle 1
g_on=$(opt group:groupbar:enabled)
if [ "$g_off" = True ] && [ "$g_on" = False ]; then ck reload_guard 0 "config-file guard through hyprctl reload: vanilla bar $g_off with the plugin unloaded, $g_on with it loaded"
else ck reload_guard 1 "unloaded=$g_off loaded=$g_on (want True / False)"; fi
if alive "$NC"; then ck reload_survives 0 "plugin load: '$out', then hyprctl reload: compositor alive"; else ck reload_survives 1 "gone after load + reload"; fi
# loaded again, nb has its border again (the config's own width now: the reloads took the test's 3) and wb's size
BL=$(bsz nb); BG=$(opt general:border_size); GL=$(geom nb); GLW=$(geom wb)
if [ "$BL" = "$BG" ] && [ "$BG" -gt 0 ] && [ "$GL" = "$GLW" ]; then ck load_forces_again 0 "after load + reload nb's border_size is $BL (general:border_size) and nb $GL == wb $GLW"
else ck load_forces_again 1 "after load + reload nb border_size $BL at $GL, wb $GLW, general border $BG"; fi

verdict
