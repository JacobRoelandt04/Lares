pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/launcher"
import "modules/picker"
import "modules/picker/data"

// =============================================================================
// mockups/picker.qml -- the emoji / symbol / Nerd Fonts picker mockup, on the REAL bar engine.
//
// A slice of the screen at 1:1: a GooeyEngine with a 40 px top bar and the launcher's slim 6 px bottom bar across the whole
// edge, and thePopup the picker rises into -- the drop-in as it will run. There is no bar button: Alt+Period (a Shortcut of this
// window; the desktop's is the same key as a Hyprland `global` bind, PickerBarOwner's header) or the Run tab opens it.
//
// THE SERVICE is the real PickerService, NOT live: the data is the committed asset, the memory (recents, tone) is in RAM, and a
// pick is recorded (the Run tab shows it: the text, the origin window it would be pasted into and its paste key) and sent
// nowhere. The Run tab seeds recents and picks the tone.
//
// Keys, in the popup (PickerPopup's header has the full list): type to search (digits on Symbols jump to an alt code), arrows,
// Tab for the other tab, Ctrl+Left / Right for the category, Enter picks, Shift+Enter adds to the tray, Ctrl+T / right-click the
// skin tone, Esc. The Nerd tab's list is fetched for the installed font the first time the tab is shown (tools/picker/nerd_fetch.py;
// the Run tab says what it did); Ctrl+Enter / Ctrl+click picks the icon's NAME where Enter picks the glyph.
//
// Scenario env for a grab: PICKER_NO_OPEN=1 (start closed), PICKER_TAB=emoji|symbols|nerd, PICKER_QUERY=<text>, PICKER_MOVE=<n> (the highlight
// n cells on), PICKER_NERD_CACHE=<dir> (the Nerd list's cache folder: a grab points it at a seeded one, so nothing is fetched), PICKER_NERD_URL=<url>
// (where the list is fetched from: an unreachable one shows the failure line), PICKER_CAT=<category id>, PICKER_SCROLL=<px> (the grid scrolled to that offset),
// PICKER_TONE=1..5 (the tone in force), PICKER_TONEPOP=1 (open the popover on the first tonable cell), PICKER_TRAY=<n> (n picks in the
// tray), PICKER_CLEAR=1 (press Clear on the shown tab: the Undo state; PICKER_UNDOMS=<ms> sets how long it is on offer), PICKER_NO_SEED=1 (no recents), PICKER_DARK=1 is the theme bar's, not here.
//
// Run it: quickshell -p mockups/picker.qml (in the sandbox when a shell is running here: tools/dev/sandbox.sh ...).
// =============================================================================
MockupWindow {
    id: win

    moduleId: "picker"
    title: "Emoji and symbol picker"
    stageLabel: "A section of the screen at 1:1 -- a top bar, the slim bottom bar, thePopup"
    content: scene
    target: sty
    targets: ({
            styleParams: sty
        })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460
    fitContent: true

    lists: ({
            styleParams: win.styleParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Popup",
            lists: ["styleParams"],
            groups: ["Popup", "Foot", "Sections"]
        },
        {
            name: "Tiles",
            lists: ["styleParams"],
            groups: ["Emoji tab", "Symbols tab", "Alt codes", "Kaomoji", "Nerd tab"]
        },
        {
            name: "Motion",
            lists: ["styleParams"],
            groups: ["Highlight", "Scroll", "Presence"]
        }
    ]

    property bool dressAudiowide: true

    PickerStyle {
        id: sty
    }

    // Not live: RAM only, nothing is pasted. The origin is what the owner would read from `hyprctl activewindow`.
    PickerService {
        id: svc
        live: false
        origin: ({ address: "0x55d0c2a1b2c0", cls: "firefox" })
        nerdCacheOverride: Quickshell.env("PICKER_NERD_CACHE") || ""
        nerdUrlBase: Quickshell.env("PICKER_NERD_URL") || ""
    }

    Item {
        id: scene
        implicitWidth: 1180
        implicitHeight: 800

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: pickEngine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [topBar, pickBar]

            GooeyBar {
                id: topBar
                engine: pickEngine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: pickEngine.w
                Text {
                    x: topBar.width - width - 18
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }

            LauncherBar {
                id: pickBar
                engine: pickEngine
                barId: "pickBar"
                rawPos: 0
                rawLen: pickEngine.w
            }
        }

        PickerBarOwner {
            id: owner
            engine: pickEngine
            bar: pickBar
            barId: "pickBar"
            service: svc
            // The linter sees this type twice -- once through the mockup's `modules` link, once at its real path -- and calls the two
            // incompatible; the engine follows the link and sees one (mockups/modules: RepoRoot.qml).
            // qmllint disable incompatible-type
            style: sty
            // qmllint enable incompatible-type
            fontFamily: win.dressAudiowide ? "Audiowide" : "Inter"
            // A mockup never registers the desktop's shortcut, and has no compositor to ask which window the paste is for.
            shortcutEnabled: false
            liveWindow: false
        }
    }

    // Alt+Period, the desktop's bind: the same toggle.
    Shortcut {
        sequence: "Alt+."
        context: Qt.WindowShortcut
        onActivated: owner.toggle()
    }

    // ---- Seeds and scenario hooks ------------------------------------------------------------------
    function seedRecents() {
        const ix = svc.index;
        if (!ix)
            return;
        const picks = ["😂", "❤️", "👍", "🙏", "🔥", "🎉", "😊", "🤔", "👋", "✅", "😭", "é", "€", "→", "π", "°", "(╯°□°）╯︵ ┻━┻"];
        // frecency: a few more picks of the first ones, so the order is not the list's
        const saved = svc.origin;
        for (let r = 0; r < 3; r++)
            for (let i = 0; i < picks.length - r * 4; i++)
                if (ix.byChar[picks[i]])
                    svc.pick(picks[i], [picks[i]]);
        svc.origin = saved;
        svc.lastPick = null;
        svc.picks = 0;
    }
    // Some Nerd picks too, once the list is there (the Nerd tab's own Recent section).
    function seedNerd() {
        const nx = svc.nerdIndex;
        if (!nx)
            return;
        const names = ["nf-md-home", "nf-md-lightbulb_on", "nf-fa-flag", "nf-cod-bug", "nf-linux-archlinux", "nf-md-battery_charging", "nf-oct-rocket"];
        const want = {};
        for (let i = 0; i < names.length; i++)
            want[names[i]] = names.length - i;
        const saved = svc.origin;
        for (let k = 0; k < nx.items.length; k++) {
            const n = want[nx.items[k].name];
            for (let r = 0; r < (n || 0); r++)
                svc.pick(nx.items[k].ch, [nx.items[k].ch]);
        }
        svc.origin = saved;
        svc.lastPick = null;
        svc.picks = 0;
    }
    function forgetAll() {
        svc.clearMemory();
    }
    // The popup's content while it exists.
    readonly property var content_: owner._content
    function scenario() {
        const c = owner._content;
        if (!c)
            return;
        const tab = Quickshell.env("PICKER_TAB") || "";
        if (tab !== "")
            c.setTab(tab);
        // the Nerd list is fetched or read when the tab is first shown: the rest of the scenario waits for it
        if (tab === "nerd" && svc.nerdState !== "ready") {
            nerdWait.start();
            return;
        }
        win.scenarioRest(c);
    }
    function findNamed(item, name) {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = win.findNamed(item.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    function scenarioRest(c) {
        if (Quickshell.env("PICKER_NO_SEED") !== "1")
            win.seedNerd();
        const tone = Number(Quickshell.env("PICKER_TONE") || 0);
        if (tone > 0)
            svc.setTone(tone);
        const q = Quickshell.env("PICKER_QUERY") || "";
        if (q !== "")
            c.setQuery(q);
        // PICKER_CLEAR=1: press Clear on this tab (the Undo state); PICKER_UNDOMS=<ms> shortens how long it stays on offer
        if (Number(Quickshell.env("PICKER_UNDOMS") || 0) > 0)
            sty.undoMs = Number(Quickshell.env("PICKER_UNDOMS"));
        if ((Quickshell.env("PICKER_CLEAR") || "") === "1")
            Qt.callLater(() => c.clearRecents());
        const mv = Number(Quickshell.env("PICKER_MOVE") || 0);
        if (mv > 0)
            Qt.callLater(() => c.moveTo(mv));
        const cat = Quickshell.env("PICKER_CAT") || "";
        if (cat !== "")
            Qt.callLater(() => c.jumpToCat(cat));
        // PICKER_SCROLL=<px>: the grid's own scroll position, so a grab can stand glyphs under the end fades (the fade check)
        const sc = Quickshell.env("PICKER_SCROLL") || "";
        if (sc !== "") {
            const g = win.findNamed(c, "pickerGrid");
            if (g)
                Qt.callLater(() => g.scrollTo(Number(sc), false));
        }
        const n = Number(Quickshell.env("PICKER_TRAY") || 0);
        for (let i = 0; i < n; i++)
            c.addTray(c.lay.flat[Math.min(c.lay.flat.length - 1, 3 + 2 * i)]);
        if ((Quickshell.env("PICKER_TONEPOP") || "") === "1") {
            for (let i = 0; i < c.lay.flat.length; i++) {
                if (c.lay.flat[i].tonable) {
                    c.moveTo(i);
                    c.openToneFor(i);
                    break;
                }
            }
        }
    }
    Timer {
        id: nerdWait
        interval: 100
        repeat: true
        onTriggered: {
            if (svc.nerdState === "loading")
                return;
            nerdWait.stop();
            if (owner._content)
                win.scenarioRest(owner._content);
        }
    }
    Timer {
        id: openTimer
        interval: 80
        running: Quickshell.env("PICKER_NO_OPEN") !== "1"
        onTriggered: {
            svc.ensureLoaded();
            if (Quickshell.env("PICKER_NO_SEED") !== "1")
                win.seedRecents();
            owner.open();
            scenarioTimer.start();
        }
    }
    Timer {
        id: scenarioTimer
        interval: 700
        onTriggered: win.scenario()
    }
    Timer {
        running: Quickshell.env("PICKER_DEBUG") === "1"
        interval: 2000
        onTriggered: {
            const c = owner._content;
            console.log("PICKERDBG rows " + c.lay.rows.length + " height " + c.lay.height + " flat " + c.lay.flat.length + " cur " + c.currentIndex + " y " + c.lay.secY["kaomoji"]);
        }
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property string pickText: {
        const p = svc.lastPick;
        if (!p)
            return "nothing picked yet";
        const cps = Array.from(p.text).map(c => "U+" + c.codePointAt(0).toString(16).toUpperCase()).join(" ");
        return "pasted \"" + p.text + "\"  (" + p.bases.length + " pick" + (p.bases.length === 1 ? "" : "s") + ")\n" + cps
            + "\ninto " + (p.origin ? p.origin.cls + " " + p.origin.address : "no window (copy only)") + (p.pasteKey !== "" ? "  with " + p.pasteKey : "");
    }

    readonly property string nerdText: {
        const r = svc.nerdResult;
        if (svc.nerdState === "idle")
            return "not asked yet (open the Nerd tab)";
        if (svc.nerdState === "loading")
            return "asking the tool ...";
        if (svc.nerdState === "error")
            return "error: " + svc.nerdError;
        return "Nerd Fonts " + (r ? r.nerd : "?") + ", " + svc.nerdFamily + ": " + (r ? r.count : "?") + " icons, " + (r && r.fetched ? "fetched now" : "no fetch") + "  (" + (r ? r.status : "") + ")";
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "The popup"
                blurb: "Open and close it as the Alt+Period bind does."
            }
            TipRow {
                tip: "Open or close the picker as the bind does: the keyboard is the popup's at once. Escape closes the tone popover, then clears the search, then the tray, then closes. A pick copies, closes the popup, and (on the desktop) pastes into the window it was opened over."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: owner.popupMine ? "Close" : "Open (Alt+.)"
                    onClicked: owner.toggle()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Dress the popup's header, tabs and captions in Audiowide, as the other mockups are. The module's own face is Inter; the tiles are the system's colour emoji and symbol fonts either way."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "Audiowide"
                    checked: win.dressAudiowide
                    onToggled: win.dressAudiowide = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "What it remembers"
                blurb: "Recents and the one skin tone. In RAM here; on the desktop ~/.local/state/lares/picker/state.json."
            }
            TipRow {
                tip: "Seed the Recent row with some picks the way a week of use would (frecency: how often AND how lately), or forget everything: the row goes, the tone goes."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Seed recents"
                    onClicked: {
                        win.seedRecents();
                        win.seedNerd();
                    }
                }
                Button {
                    text: "Forget all"
                    onClicked: win.forgetAll()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The ONE global skin tone, as a right-click on any emoji that takes one (or the hand in the foot, or Ctrl+T) sets it. 0 is no tone. Every tonable emoji in the grid, the recents and the pick follows it at once."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: [0, 1, 2, 3, 4, 5]
                    delegate: Button {
                        required property int modelData
                        text: modelData === 0 ? "none" : "tone " + modelData
                        highlighted: svc.tone === modelData
                        onClicked: svc.setTone(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The Nerd Fonts list"
                blurb: "Fetched for the installed font's version, cached, asked once per shell."
            }
            TipRow {
                tip: "Ask for the Nerd Fonts list again, as the next visit to the tab does after a failure (a list already there is kept: the tool runs once per shell). The line below says what the tool answered: the version it read from the font, whether it fetched, how many icons the font draws."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Ask again"
                    enabled: svc.nerdState !== "loading" && svc.nerdState !== "ready"
                    onClicked: svc.ensureNerd()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.nerdText
            }

            TipGroup {
                title: "What the service was told"
                blurb: "A pick touches no clipboard and sends no key here; this is the call the real one would have made."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.pickText + "\npicks " + svc.picks + "   tone " + svc.tone + "   data " + (svc.ready ? svc.index.emoji.length + " emoji, " + svc.index.symbols.length + " symbols" : "not loaded")
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var styleParams: [
        {
            label: "emoji columns",
            prop: "emojiCols",
            group: "Popup",
            blurb: "How wide the popup is.",
            tip: "The popup is this many Emoji cells wide (plus the grid box's padding and the popup's 12 px). 12 columns of 44 px is 564 px: wide enough for the foot's category bar, a caption and the tone button without dead space, narrow enough to rise out of the bottom bar's middle.",
            val: 12,
            from: 6,
            to: 16,
            step: 1
        },
        {
            label: "grid height",
            prop: "gridHeight",
            group: "Popup",
            tip: "Height of the carved grid box. 276 shows six emoji rows and a header's worth: the popup never resizes through a tab or a search, so this is its whole height budget.",
            val: 276,
            from: 140,
            to: 520,
            step: 2
        },
        {
            label: "box padding",
            prop: "boxPad",
            group: "Popup",
            tip: "Space between the grid box's edge and the first tile, px. 6, the shell's list-row inset.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "box radius",
            prop: "boxRadius",
            group: "Popup",
            tip: "Corner radius of the grid box and of the fades' outline. 14, the shell's container radius.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "category cell",
            prop: "catCell",
            group: "Foot",
            blurb: "The category bar under the grid.",
            tip: "Width of one category glyph in the bar. 32 fits nine emoji categories in 288 px and leaves the caption room.",
            val: 32,
            from: 24,
            to: 44,
            step: 1
        },
        {
            label: "foot height",
            prop: "catHeight",
            group: "Foot",
            tip: "Height of the foot line (the category bar, the caption, the tone button).",
            val: 30,
            from: 24,
            to: 40,
            step: 1
        },
        {
            label: "badge size",
            prop: "badgeSize",
            group: "Foot",
            tip: "Diameter of the tray badge on a picked tile (how many times it is in the pick).",
            val: 14,
            from: 10,
            to: 22,
            step: 1
        },
        {
            label: "tone cell",
            prop: "toneCell",
            group: "Foot",
            blurb: "The skin-tone popover.",
            tip: "Width of one tone in the popover (six of them).",
            val: 38,
            from: 28,
            to: 56,
            step: 1
        },
        {
            label: "tone glyph",
            prop: "toneGlyph",
            group: "Foot",
            tip: "Size of the hand in each tone cell, logical px.",
            val: 24,
            from: 14,
            to: 36,
            step: 1
        },
        {
            label: "header height",
            prop: "headH",
            group: "Sections",
            blurb: "Sections: Recent, then a category each.",
            tip: "Height of a section's header row (its label). The label sits on the row's foot, so the air above it separates sections.",
            val: 26,
            from: 18,
            to: 40,
            step: 1
        },
        {
            label: "section gap",
            prop: "sectionGap",
            group: "Sections",
            tip: "Air between the last tile row of a section and the next header.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "recent rows",
            prop: "recentRows",
            group: "Sections",
            tip: "How many rows the Recent section may take (its picks by frecency). One row is what the mobile keyboards show; more is more memory in view and less of the categories.",
            val: 1,
            from: 1,
            to: 4,
            step: 1
        },
        {
            label: "clear button height",
            prop: "clearHeight",
            group: "Sections",
            blurb: "The Clear control at the right end of the Recent header (it becomes the Undo).",
            tip: "Height of the Clear / Undo plate. 20: it stands on the header label's line inside the 26 px header row, so its shadow does not reach into the tiles below.",
            val: 20,
            from: 16,
            to: 26,
            step: 1
        },
        {
            label: "undo ms",
            prop: "undoMs",
            group: "Sections",
            tip: "How long the Undo that Clear turns into stays on offer, draining in the button's own shading. 10000, as the notification manager's Clear all.",
            val: 10000,
            from: 1000,
            to: 30000,
            step: 500
        },
        {
            label: "emoji cell",
            prop: "emojiCell",
            group: "Emoji tab",
            blurb: "A square cell.",
            tip: "Width and height of one Emoji cell. 44: a 26 px glyph with room for the highlight well and the badge. The popup's width follows (emoji columns x this).",
            val: 44,
            from: 32,
            to: 64,
            step: 1
        },
        {
            label: "emoji glyph",
            prop: "emojiGlyph",
            group: "Emoji tab",
            tip: "Size of an emoji, logical px. Noto Color Emoji's bitmaps are 136 px, so it stays sharp up to about 100 px at any shell scale.",
            val: 26,
            from: 14,
            to: 40,
            step: 1
        },
        {
            label: "symbol cell",
            prop: "symbolCell",
            group: "Symbols tab",
            blurb: "Math, arrows, currency, Greek.",
            tip: "The narrowest a symbol cell may be (square); as many as fit the width are made, and share it.",
            val: 48,
            from: 32,
            to: 72,
            step: 1
        },
        {
            label: "symbol glyph",
            prop: "symbolGlyph",
            group: "Symbols tab",
            tip: "Size of a symbol, logical px.",
            val: 22,
            from: 12,
            to: 36,
            step: 1
        },
        {
            label: "alt cell width",
            prop: "altCellW",
            group: "Alt codes",
            blurb: "The glyph with its code(s) under it.",
            tip: "The narrowest an alt-code cell may be. Wide enough for the two codes of a character that has both (130 · 0233) in the small caption.",
            val: 64,
            from: 48,
            to: 96,
            step: 1
        },
        {
            label: "alt cell height",
            prop: "altCellH",
            group: "Alt codes",
            tip: "Height of an alt-code cell: the glyph and the caption under it.",
            val: 56,
            from: 40,
            to: 80,
            step: 1
        },
        {
            label: "alt glyph",
            prop: "altGlyph",
            group: "Alt codes",
            tip: "Size of the glyph on an alt-code cell, logical px.",
            val: 22,
            from: 12,
            to: 36,
            step: 1
        },
        {
            label: "alt caption",
            prop: "altCaption",
            group: "Alt codes",
            tip: "Size of the code caption under the glyph, logical px. Inter, always: Audiowide has no tabular figures.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "kaomoji width",
            prop: "wideCellW",
            group: "Kaomoji",
            blurb: "Wide cells, one line, cut at the right.",
            tip: "The narrowest a kaomoji cell may be: 258 makes two columns in the default popup.",
            val: 258,
            from: 120,
            to: 540,
            step: 2
        },
        {
            label: "kaomoji height",
            prop: "wideCellH",
            group: "Kaomoji",
            tip: "Height of a kaomoji cell.",
            val: 34,
            from: 24,
            to: 56,
            step: 1
        },
        {
            label: "kaomoji glyph",
            prop: "wideGlyph",
            group: "Kaomoji",
            tip: "Size of a kaomoji, logical px.",
            val: 14,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "nerd cell",
            prop: "nerdCell",
            group: "Nerd tab",
            blurb: "Icons of the installed Nerd Font, by name.",
            tip: "Width and height of one icon cell (about eleven fit the default popup). 44, as an emoji's: the icons are drawn at nerd glyph px inside it.",
            val: 44,
            from: 32,
            to: 64,
            step: 1
        },
        {
            label: "nerd glyph",
            prop: "nerdGlyph",
            group: "Nerd tab",
            tip: "Size of an icon, logical px. Nerd Font glyphs are drawn on a 1 em box, so 24 fills a 44 px cell with room for the well.",
            val: 24,
            from: 12,
            to: 40,
            step: 1
        },
        {
            label: "nerd category cell",
            prop: "nerdCatCell",
            group: "Nerd tab",
            tip: "Width of one icon-set glyph in the category bar on this tab. Eleven sets at 28 px take 308 px and leave the highlighted icon's name about 220 px; the other tabs use the foot's category cell.",
            val: 28,
            from: 22,
            to: 40,
            step: 1
        },
        {
            label: "well radius",
            prop: "wellRadius",
            group: "Highlight",
            blurb: "The carved well that glides between cells.",
            tip: "Corner radius of the highlight well. 10, the radius of a carved box inside a container.",
            val: 10,
            from: 2,
            to: 22,
            step: 1
        },
        {
            label: "well inset",
            prop: "wellInset",
            group: "Highlight",
            tip: "How far the well stands in from its cell's edge, so neighbouring wells never touch and the bevel is not cut.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "glide ms",
            prop: "glideMs",
            group: "Highlight",
            tip: "How long the well takes to go from one cell to the next (OutCubic). It snaps where the page is replaced (a new search, a tab). 140 reads as one motion, not a lag.",
            val: 140,
            from: 0,
            to: 500,
            step: 10
        },
        {
            label: "jump scroll ms",
            prop: "scrollMs",
            group: "Scroll",
            blurb: "The shell's wheel feel is tuned on the clipboard mockup's Scrolling tab.",
            tip: "How long a keyboard step or a category jump scrolls the grid (OutCubic). The wheel and the touchpad use the shell's one scroll feel, never this.",
            val: 220,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "fade height",
            prop: "fadeHeight",
            group: "Scroll",
            tip: "Height of the fade at the grid box's ends, where the content runs on. 24, as the launcher's.",
            val: 24,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "presence ms",
            prop: "presenceMs",
            group: "Presence",
            blurb: "What appears and goes fades; words swap at once.",
            tip: "The fade of the empty page, the tone button and the tone popover. 160, the shell's presence fade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]
}
