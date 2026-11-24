#!/usr/bin/env bash
# panorama_tabs_probe.sh -- the machine popup: ONE popup, two tabs (Displays | Presets; modules/panorama/popup/PanoramaTabs.qml and
# PanoramaBarOwner.qml) on the mock services, a stand-in engine, a shell-hosted owner (tools/dev/qml/panorama_tabs_probe.qml: the checks are listed
# in its header), offscreen.
#
#   tools/dev/panorama_tabs_probe.sh                 PANORAMA_TABS RESULT PASS | FAIL
#   ARM=<name> tools/dev/panorama_tabs_probe.sh      patches ONE rule in the sandbox copy: the run must go red on its own check
#       nosituation   the owner always opens Displays                      (situation)
#       openwith      Arrange... does not force Displays                   (situation: openWith)
#       latch         both tabs are built at once                          (built)
#       nomemo        a tab's first show is a step to the header and a second to the tab   (size)
#       nobinding     the owner's tab never reaches a content whose own binding died   (held)
#       swipe         a sideways swipe moves nothing                       (swipe)
#       noaxis        the axis lock is gone: a vertical scroll with drift switches   (swipe)
#       escape        Escape asks the Displays tab whatever is on show     (escape)
#       detailstays   a tab left keeps the selected display               (detail: it comes back with the tab)
#       detailtab     the detail stays open on the Presets tab            (detail)
#       kbd           the keyboard request is always none                  (keys)
#       unbuilt       a Presets tab not built yet aims at two columns whatever is saved   (size)
#       flag          popupOpen is "the popup is open", on any tab         (flag)
#       deal          a load asks the glyph for nothing                    (deal)
#       dealapply     every close deals, an Apply too                      (deal)
#       nowatch       the Presets tab on show never holds the presets' watch (the save card frozen)   (watch)
#   ARM=all                                          the clean run, then every arm; PANORAMA_TABS ARMS PASS | FAIL
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-tabs}"
ARMS="nosituation openwith latch nomemo nobinding swipe noaxis escape detailstays detailtab kbd unbuilt flag deal dealapply opentab nowatch"

if [ "${ARM:-}" = all ]; then
    bad=0
    out=$(ARM= "$0" 2>&1); echo "$out" | tail -1
    echo "$out" | tail -1 | grep -q "RESULT PASS" || bad=1
    for a in $ARMS; do
        r=$(ARM=$a "$0" 2>&1)
        if rl_isnoresult "$r"; then echo "ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif echo "$r" | grep -q "RESULT FAIL"; then echo "ARM $a: fails as it must ($(echo "$r" | grep -c 'PT FAIL') checks: $(echo "$r" | grep -a 'PT FAIL' | head -1 | cut -c1-90))"
        else echo "ARM $a: DID NOT FAIL"; bad=1; fi
    done
    [ $bad = 0 ] && echo "PANORAMA_TABS ARMS PASS" || echo "PANORAMA_TABS ARMS FAIL"
    exit $bad
fi

LOG=$(mktemp "${SCRATCH:-/tmp}/panotabs.XXXXXX")
trap 'rm -f "$LOG"' EXIT
O=modules/panorama/PanoramaBarOwner.qml
T=modules/panorama/popup/PanoramaTabs.qml
# one patch = file@@anchor@@replacement; several are joined with a line holding only ====
patch=""
case "${ARM:-}" in
    "") ;;
    opentab)     patch="$O@@        if (owner.openTab === \"displays\" || owner.openTab === \"presets\")
            return owner.openTab;@@" ;;
    nosituation) patch="$O@@        return more || s.mirroring === true || s.castActive === true ? \"displays\" : \"presets\";@@        return \"displays\";" ;;
    openwith)    patch="$O@@        owner.currentTab = \"displays\";
        if (owner.popupMine@@        if (owner.popupMine" ;;
    latch)       patch="$T@@        active: root.eager || root.currentTab === \"displays\" || root._panoShown@@        active: true" ;;
    nomemo)      patch="$T@@        return root._memo.h > 0 ? root._memo.h : root._headH;@@        return root._headH + h;" ;;
    nobinding)   patch="$O@@            Binding {
                target: content
                property: \"currentTab\"
                value: owner.currentTab
                restoreMode: Binding.RestoreNone
            }@@" ;;
    swipe)       patch="$T@@            tabSel.applySwipe(dx);@@            void dx;" ;;
    noaxis)      patch="$T@@        if (root._gestureAxis === \"x\" && dx !== 0)@@        if (dx !== 0)" ;;
    escape)      patch="$T@@        const t = root.currentTab === \"presets\" ? root.presetsTab : root.displaysTab;@@        const t = root.displaysTab;" ;;
    detailstays) patch="$T@@            root.selected = \"\";
            root._endGesture();
        }
    }@@            root._endGesture();
        }
    }" ;;
    detailtab)   patch="$T@@    readonly property bool _detailOn: root.currentTab === \"displays\" && !!root.displaysTab@@    readonly property bool _detailOn: !!root.displaysTab
====
$T@@            root.selected = \"\";
            root._endGesture();
        }
    }@@            root._endGesture();
        }
    }" ;;
    kbd)         patch="$T@@    readonly property string keyboardFocusRequest: root.currentTab === \"presets\" && root.presetsTab ? String(root.presetsTab.keyboardFocusRequest) : \"none\"@@    readonly property string keyboardFocusRequest: \"none\"" ;;
    unbuilt)     patch="$T@@        : root.presetsStyle.widthFor((root.presets ? root.presets.presets.length : 0) + 1)@@        : root.presetsStyle.widthFor(2)" ;;
    flag)        patch="$O@@            popupOpen: owner.popupMine && owner.currentTab === \"displays\"@@            popupOpen: owner.popupMine" ;;
    deal)        patch="$O@@            if (owner.anchorItem && typeof owner.anchorItem.deal === \"function\")@@            if (false)" ;;
    dealapply)   patch="$T@@                onCloseRequested: root.closeRequested()
            }
        }
    }
    Loader {
        id: presLoader@@                onCloseRequested: {
                    root.presetLoadStarted();
                    root.closeRequested();
                }
            }
        }
    }
    Loader {
        id: presLoader" ;;
    nowatch)     patch="$O@@            owner.presets.holdWatch(owner);@@            void 0;" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
armpy='import sys
for one in sys.argv[1].split("\n====\n"):
    f,a,b=one.split("@@",2); s=open(f).read()
    if s.count(a)!=1: print("ARM anchor gone: "+a); sys.exit(1)
    open(f,"w").write(s.replace(a,b))'
run='set -e; PRIV=$(mktemp -d /tmp/panotabs-env.XXXXXX); mkdir -p $PRIV/config/theme $PRIV/state $PRIV/cache; printf "{\"theme\":\"eva\",\"mode\":\"light\"}\n" > $PRIV/config/theme/state.json; '
[ -n "$patch" ] && run="$run python3 -c '$armpy' $(printf '%q' "$patch"); "
run="$run"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PANORAMA_TABS=1 XDG_CONFIG_HOME=$PRIV/config XDG_STATE_HOME=$PRIV/state XDG_CACHE_HOME=$PRIV/cache tools/dev/notifications_bus.sh timeout -k 2 120 quickshell -p tools/dev/qml/panorama_tabs_probe.qml; rm -rf $PRIV'
tools/dev/sandbox.sh bash -c "$run" > "$LOG" 2>&1
rl_clean "$LOG" | grep -a -E "PT (ok|FAIL)" | sed "s/^.*PT /PT /"
if [ -n "${ARM:-}" ]; then
    if rl_isnoresult "$(rl_result PANORAMA_TABS "$LOG" 'PT RESULT .*')"; then echo "PANORAMA_TABS RESULT FAIL (no result: armed copy)"; exit 1; fi
    rl_clean "$LOG" | grep -a "PT RESULT" | sed 's/PT RESULT/PANORAMA_TABS RESULT/'
    exit 0
fi
cp "$LOG" /tmp/panotabs.last.log
# a clean run is clean: no warning of ours in the log
if rl_clean "$LOG" | grep -a -E 'panorama/|presets/|panorama_tabs_probe' | grep -a -i -E 'warn|error|unable|cannot|binding loop|TypeError|ReferenceError'; then
    echo "PANORAMA_TABS RESULT FAIL (warnings in the log: /tmp/panotabs.last.log)"; exit 1
fi
res=$(rl_result PANORAMA_TABS "$LOG" 'PT RESULT .*'); rc=$?
printf '%s\n' "$res" | sed 's/^PT RESULT/PANORAMA_TABS RESULT/'
exit $rc
