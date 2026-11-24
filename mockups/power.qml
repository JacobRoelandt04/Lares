pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/bar/reel"

// =============================================================================
// mockups/power.qml -- the reel, in a real bar, using thePopup.
//
// This module is NOT a drop-in for thePopup the way the others are. It is half
// in the bar and half hanging out of it, and the join between them is the
// design: the curve that grows out of the bar's edge, the half-round far end,
// the popup sliding from one module to the next -- around a corner onto
// another bar, even -- are the gooey engine's, not this module's. So the stage
// carries a real GooeyEngine with two bars on it, over a section of the actual
// wallpaper at 1:1, and the module is mounted in them the way it will be.
//
// FOUR INSTANCES, because being right means being right in all of them: the
// power menu and the idle inhibitor, on a horizontal bar and on a vertical
// one. They share ONE IconReelStyle -- the panel's target -- so a value moves
// in all four at once, which is the only way to see whether it is right.
// There is one thePopup, so hovering another module MIGRATES it, which is
// exactly what the bar does in life.
//
// NOTHING IS FIRED. `activated` runs `notify-send` with the command in the
// body and never the command itself. There is no path in this file that can
// power the machine off.
//
//   quickshell -p mockups/power.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "power"
    title: "Power / idle-inhibit reel"
    stageLabel: "A section of the screen at 1:1 — two bars, four reels, the reel slot beside thePopup"
    content: scene
    target: sharedStyle
    targets: ({
            engineParams: engine
        })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460

    lists: ({
            reelGeom: win.reelGeom,
            reelMotion: win.reelMotion,
            reelPopup: win.reelPopup,
            reelSwipe: win.reelSwipe,
            reelFog: win.reelFog,
            reelSparks: win.reelSparks,
            engineParams: win.engineParams,
            reelColors: win.reelColors
        })
    themedLists: ["reelColors"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Reel",
            subs: [
                {
                    name: "Shape",
                    lists: ["reelGeom"]
                },
                {
                    name: "Motion",
                    lists: ["reelMotion", "reelPopup"]
                },
                {
                    name: "Swipe",
                    lists: ["reelSwipe"]
                },
                {
                    name: "Fog & sparks",
                    lists: ["reelFog", "reelSparks"]
                },
                {
                    name: "Colours",
                    lists: ["reelColors"]
                }
            ]
        },
        {
            name: "Bar",
            lists: ["engineParams"]
        }
    ]

    // =====================================================================
    //  THE TWO ITEM SETS
    //
    // Glyphs are Material Design Nerd Font codepoints, written as \u{XXXXX}
    // escapes so the source survives any 3-byte PUA mangling -- the same
    // form AudioBarButton uses. `tint` names a Theme token, never a colour.
    // `command` is read by the HOST (this file), never by the reel.
    // =====================================================================
    readonly property var powerItems: [
        {
            id: "sleep",
            glyph: "\u{F0904}",
            label: "Sleep",
            tint: "power.sleep",
            command: "systemctl suspend"
        },
        {
            id: "poweroff",
            glyph: "\u{F0425}",
            label: "Power off",
            tint: "power.poweroff",
            command: "systemctl poweroff"
        },
        {
            id: "reboot",
            glyph: "\u{F0709}",
            label: "Reboot",
            tint: "power.reboot",
            command: "systemctl reboot"
        },
        {
            id: "hibernate",
            glyph: "\u{F0717}",
            label: "Hibernate",
            tint: "power.hibernate",
            command: "systemctl hibernate"
        },
        {
            id: "logout",
            glyph: "\u{F0343}",
            label: "Log out",
            tint: "power.logout",
            command: "hyprctl dispatch exit"
        },
        {
            id: "lock",
            glyph: "\u{F033E}",
            label: "Lock",
            tint: "power.lock",
            command: Quickshell.env("HOME") + "/.local/bin/lares-lock"
        }
    ]

    // Placeholder commands: what each mode MEANS is the next round's work
    // (docs/idle.md), so what the notification shows is the
    // intent, in the shape of the command it will become.
    readonly property var inhibitItems: [
        {
            id: "off",
            glyph: "\u{F04B2}",
            label: "Idle allowed",
            tint: "idle.off",
            command: "systemctl --user start hypridle"
        },
        {
            id: "soft",
            glyph: "\u{F059B}",
            label: "Soft — dim, never blank",
            tint: "idle.soft",
            command: "idle-inhibit soft   (dim on idle, no blank, no sleep)"
        },
        {
            id: "normal",
            glyph: "\u{F0176}",
            label: "Normal — no idle actions",
            tint: "idle.normal",
            command: "systemctl --user stop hypridle"
        },
        {
            id: "hard",
            glyph: "\u{F06E4}",
            label: "Hard — no sleep at all",
            tint: "idle.hard",
            command: "systemd-inhibit --what=handle-lid-switch:sleep:idle --who=lares"
        }
    ]

    // How far along its bar each module sits. Far enough from the corner
    // that thePopup is not within the engine's snap distance of the
    // perpendicular bar: inside it the popup STRETCHES toward that bar and
    // merges with it, which is the engine doing exactly what it should and
    // is not what a module wants to be judged through. MODALONG=<px> puts
    // them elsewhere -- in the corner's pull, or at a bar's end with TOPLEN
    // -- where the strip must still line up with its cell.
    readonly property real modAlong: Number(Quickshell.env("MODALONG") || 150)
    readonly property real modGap: 8
    // LEFTT=<px> makes the left bar the shell's SLIM one -- that thick, no reels in it -- so a reel on
    // the top bar at the start of the island sits where the assembly puts the power reel: a few
    // pixels from a 6 px bar standing across its end (THE WALL's zone).
    readonly property real leftThickness: Number(Quickshell.env("LEFTT") || 0)

    // One style for all four reels: they are one material, and the panel has
    // one target.
    IconReelStyle {
        id: sharedStyle
    }

    // =====================================================================
    //  THE WALLPAPER
    //
    // The real one, at 1:1, top-left corner: the stage is a SECTION of the
    // screen, not a picture of the whole of it, so the bar's 40 px and the
    // reel's icons are the size they will actually be. It follows the theme:
    // the picture shell.jsonc's theme.wallpapers names for the pair and mode
    // (MockupWallpaper).
    // =====================================================================
    MockupWallpaper {
        id: stageWall
    }
    // Fit by default: a wallpaper's top-left corner is often a pale sky, and
    // a mockup that shows two pale bars on it shows nothing.
    // 1:1 is one checkbox away and is the honest picture of that corner --
    // worth looking at, because a light bar on a light sky is a real case.
    property bool wallpaperFit: true
    readonly property string wallpaper: stageWall.source

    // =====================================================================
    //  THE STAGE: A SECTION OF THE SCREEN
    // =====================================================================
    Item {
        id: scene
        clip: true
        implicitWidth: 940
        implicitHeight: 620

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        Image {
            anchors.fill: parent
            source: win.wallpaper
            asynchronous: true
            cache: true
            fillMode: win.wallpaperFit ? Image.PreserveAspectCrop : Image.Pad
            horizontalAlignment: Image.AlignLeft
            verticalAlignment: Image.AlignTop
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            // Anything inside the engine that captures itself into a texture
            // (the reel's rounded end) needs to know what the stage is
            // magnifying it by, or it is drawn at the size the texture was
            // made and softens while everything around it stays sharp.
            renderScale: win.stage.zoom
            // The bars and thePopup are the shell's surface, so a module
            // carved out of that surface is invisible against the bar it
            // sits in and only what hangs out of it has an edge.
            surfaceColor: Theme.surface
            barsList: [topBar, leftBar]

            // ---- The horizontal bar -------------------------------------
            GooeyBar {
                id: topBar
                engine: engine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                // TOPLEN=<px> ends the top bar mid-screen (its END: THE BAR'S
                // END is what a module near it would meet).
                rawLen: Number(Quickshell.env("TOPLEN") || 0) > 0 ? Number(Quickshell.env("TOPLEN")) : engine.w

                ReelBarModule {
                    id: topPower
                    x: win.modAlong
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "power-top"
                    style: sharedStyle
                    items: win.powerItems
                    // the flourishes play here as in the shell: on the pointer's arrival, as an icon is turned into the cell, and on a fire (which runs notify-send only)
                    flourishes: ReelFlourishes {}
                    onActivated: (index, item) => {
                        topPower.flourishes.play(item.id);
                        win.fire("Power", item);
                    }
                }
                ReelBarModule {
                    id: topInhibit
                    x: win.modAlong + sharedStyle.thickness + win.modGap
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "inhibit-top"
                    style: sharedStyle
                    items: win.inhibitItems
                    leftClickActivates: true
                    // the idle reel's flourishes, as in the shell: on the pointer's arrival and as an icon is turned into the cell
                    flourishes: IdleFlourishes {}
                    onActivated: (index, item) => win.fire("Idle inhibit", item)
                }

                // One neutral bar element, so the reel's icon can be judged
                // against something the bar already carries. Not on a bar
                // TOPLEN has shortened: it sits at the bar's end, which is
                // where a module is put to meet THE BAR'S END.
                Text {
                    visible: !(Number(Quickshell.env("TOPLEN") || 0) > 0)
                    x: topBar.width - width - 18
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }

            // ---- The vertical bar ---------------------------------------
            // rawPos is measured from the top of the screen and the bar's own
            // local x runs from its FAR end back, so a module `n` px below the
            // top of the bar sits at local x = rawLen - n - width.
            GooeyBar {
                id: leftBar
                engine: engine
                barId: "leftBar"
                edge: "left"
                rawPos: topBar.thickness
                rawLen: engine.h - topBar.thickness
                thickness: win.leftThickness > 0 ? win.leftThickness : engine.thickness

                ReelBarModule {
                    id: leftPower
                    visible: win.leftThickness <= 0
                    x: leftBar.width - win.modAlong - width
                    engine: engine
                    bar: leftBar
                    barId: "leftBar"
                    ownerId: "power-left"
                    style: sharedStyle
                    items: win.powerItems
                    // the flourishes play here as in the shell: on the pointer's arrival, as an icon is turned into the cell, and on a fire (which runs notify-send only)
                    flourishes: ReelFlourishes {}
                    onActivated: (index, item) => {
                        leftPower.flourishes.play(item.id);
                        win.fire("Power", item);
                    }
                }
                ReelBarModule {
                    id: leftInhibit
                    visible: win.leftThickness <= 0
                    x: leftBar.width - win.modAlong - sharedStyle.thickness - win.modGap - width
                    engine: engine
                    bar: leftBar
                    barId: "leftBar"
                    ownerId: "inhibit-left"
                    style: sharedStyle
                    items: win.inhibitItems
                    leftClickActivates: true
                    // the idle reel's flourishes, as in the shell: on the pointer's arrival and as an icon is turned into the cell
                    flourishes: IdleFlourishes {}
                    onActivated: (index, item) => win.fire("Idle inhibit", item)
                }
            }
        }
    }

    // =====================================================================
    //  THE HOST
    //
    // notify-send, and only notify-send. The summary is what the button is,
    // the body is the command the real module will run.
    // =====================================================================
    property string lastFired: "nothing yet"
    readonly property var popupItem: engine.theReel
    readonly property var modules: [topPower, topInhibit, leftPower, leftInhibit]

    Process {
        id: notifier
        running: false
    }

    Timer {
        id: stepAt
        repeat: false
        onTriggered: {
            for (let i = 0; i < win.modules.length; i++)
                if (win.modules[i].pinnedOpen)
                    win.modules[i].reel.step(1);
        }
    }

    // Where thePopup actually is IN THE WINDOW, with the stage's
    // magnification and pan already folded in. Printed just before a grab so
    // a check measuring the PNG knows exactly where to look, instead of
    // hunting for the popup among bars that are lit the same colour.
    Timer {
        running: win.grabPath !== ""
        interval: Math.max(200, win.grabMs - 250)
        onTriggered: {
            // Untyped on purpose: thePopup is exposed as a plain Item, and its
            // box lives on dynamic properties qmllint cannot see through the
            // declared type.
            const p = win.popupItem;
            const a0 = engine.mapToItem(null, p.popX, p.popY);
            const a1 = engine.mapToItem(null, p.popX + p.popW, p.popY + p.popH);
            console.log("POPBOX " + a0.x.toFixed(2) + " " + a0.y.toFixed(2)
                + " " + (a1.x - a0.x).toFixed(2) + " " + (a1.y - a0.y).toFixed(2));
            // Whether the engine's content clip is a layer on this frame, so
            // a check forcing it (CLIP=1) can prove it really was on.
            console.log("CLIPSTATE layered=" + p.contentLayered);
        }
    }

    function fire(what, item) {
        if (!item)
            return;
        win.lastFired = what + ": " + item.label + "  —  " + item.command;
        notifier.running = false;
        notifier.command = ["notify-send", "-a", "lares", what + ": " + item.label, item.command];
        notifier.running = true;
    }

    function pin(mod) {
        for (let i = 0; i < win.modules.length; i++)
            win.modules[i].pinnedOpen = (win.modules[i] === mod);
    }

    // HOLD=<ownerId> pins one module open and WALL=<url> overrides the
    // wallpaper, so a render can ask for a state the pointer would otherwise
    // have to hold.
    Component.onCompleted: {
        // FOG=<px> overrides the fog after the panel has pushed its defaults
        // in (the framework's own onCompleted runs first). It is what lets a
        // check render the same popup with and without the fog and compare
        // the two silhouettes: the fog is OPAQUE, and any pixel it lights
        // that the bare shape does not is fog standing outside the popup.
        const fog = Quickshell.env("FOG") || "";
        if (fog !== "")
            sharedStyle.fogLength = Number(fog);
        // TAIL=<cells> pushes the last icon further into (or out of) the
        // rounded end, so a check can render an icon straddling the cap and
        // see what shape it is actually cut by.
        const seam = Quickshell.env("SEAM") || "";
        if (seam !== "")
            sharedStyle.seamOverlap = Number(seam);
        const ins = Quickshell.env("INSET") || "";
        if (ins !== "")
            sharedStyle.maskInset = Number(ins);
        // CLIP=1 keeps the engine's content clip on at rest. It is only
        // there while thePopup moves or snaps, which is exactly when a grab
        // cannot park an icon on the join; forcing it is how the seam check
        // proves that cut never reaches the near edge either.
        if ((Quickshell.env("CLIP") || "") === "1")
            engine.forceContentClip = true;
        const tail = Quickshell.env("TAIL") || "";
        if (tail !== "")
            sharedStyle.tailFraction = Number(tail);
        // STEPAT=<ms> turns the held-open reel that long after load, so a
        // grab timed just after it catches an icon CROSSING the join between
        // the bar's cell and thePopup -- the only moment the join can be seen.
        const at = Number(Quickshell.env("STEPAT") || 0);
        if (at > 0) {
            stepAt.interval = at;
            stepAt.start();
        }
        const hold = Quickshell.env("HOLD") || "";
        if (hold !== "") {
            for (let i = 0; i < win.modules.length; i++)
                win.modules[i].pinnedOpen = (win.modules[i].ownerId === hold);
        }
        // REELAT=<cells> parks the held reel at an exact, possibly fractional
        // position instead of waiting for a step to pass through one. STEPAT
        // can only catch an icon on the join by luck of the timing; this puts
        // it there. -0.5556 is icon 0 centred exactly on the join, since
        // aOf() is barCell/2 + slot * cellPitch and the join is at barCell.
        const reelAt = Quickshell.env("REELAT") || "";
        if (reelAt !== "") {
            for (let i = 0; i < win.modules.length; i++)
                if (win.modules[i].pinnedOpen)
                    win.modules[i].reel.reelPos = Number(reelAt);
        }
        if (win.alignAt > 0)
            alignShot.start();
    }

    // ALIGN=1 (with HOLD): once the held reel has settled, print where its
    // bar cell and its strip are along the bar (screen px, the scene's frame),
    // and where the scene stands IN THE WINDOW (`scene x,y`), and grab the
    // scene alone to SCENE_GRAB=<png> (engine coordinates, 1:1), so
    // a check can see that the strip continues its cell -- by
    // the boxes and by the icons' ink. The ink is judged in the WINDOW's
    // picture (GRAB=<png>, cropped at `scene`): the engine's content clip puts
    // its layer on the WINDOW's device pixel grid (GooeyBody: THE LAYERS'
    // GRID) and the stage centres the scene at a fractional position (y 211.5
    // in the gate), where a grab of the scene alone has a grid of its own and
    // a layered strip -- on at rest beside a wall or at a bar's end -- lands
    // half a pixel off it: a picture no screen shows.
    readonly property int alignAt: (Quickshell.env("ALIGN") || "") === "1" ? Number(Quickshell.env("ALIGN_MS") || 1600) : 0
    Timer {
        id: alignShot
        interval: win.alignAt
        onTriggered: {
            let mod = null;
            for (let i = 0; i < win.modules.length; i++)
                if (win.modules[i].pinnedOpen)
                    mod = win.modules[i];
            const b = engine.theReel.box;
            if (!mod || !b || !engine.reelOpen) {
                console.log("REELALIGN none: held " + !!mod + ", popup " + engine.reelOpen);
                return;
            }
            const vertical = mod.barEdge === "left" || mod.barEdge === "right";
            const c = mod.mapToItem(engine, mod.width / 2, mod.height / 2);
            const cell = vertical ? c.y : c.x;
            const strip = vertical ? (b.y0 + b.y1) / 2 : (b.x0 + b.x1) / 2;
            const at = scene.mapToItem(null, 0, 0);
            console.log("REELALIGN " + mod.ownerId + " edge " + mod.barEdge + " cell " + cell.toFixed(3)
                + " strip " + strip.toFixed(3) + " box " + [b.x0, b.y0, b.x1, b.y1].map(v => v.toFixed(2)).join(",")
                + " scene " + at.x.toFixed(3) + "," + at.y.toFixed(3)
                + " phase " + engine.theReel.phase + " t " + engine.theReel.t.toFixed(3));
            const out = Quickshell.env("SCENE_GRAB") || "";
            if (out !== "")
                scene.grabToImage(r => {
                    r.saveToFile(out);
                    console.log("REELALIGN grabbed " + out);
                });
        }
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            Label {
                Layout.fillWidth: true
                text: "Activation runs notify-send only. Nothing in this file can suspend, reboot or power off the machine."
                color: "#B34A00"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            TipGroup {
                title: "Hold one open"
                blurb: "There is one thePopup, so only one module can have it. Hovering another takes it -- around the corner onto the other bar, if that is where it went."
            }

            TipRow {
                tip: "Pins that module's reel open without the pointer, for a render or a still. Pinning one unpins the others, the same way hovering one takes thePopup from the other."
                Button {
                    text: "top power"
                    onClicked: win.pin(topPower)
                }
                Button {
                    text: "top inhibit"
                    onClicked: win.pin(topInhibit)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The same two on the vertical bar. Everything the reel does is one axis and a sign, so these are the same code with x and y swapped -- and the two-finger gesture follows the strip, not the screen."
                Button {
                    text: "left power"
                    onClicked: win.pin(leftPower)
                }
                Button {
                    text: "left inhibit"
                    onClicked: win.pin(leftInhibit)
                }
                Button {
                    text: "none"
                    onClicked: win.pin(null)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Drive it"
                blurb: "What the pointer does on the module: hover opens it, wheel or two-finger scroll turns it, left click slides an icon into the bar, right click fires the one that is there (either button, on the inhibitor)."
            }

            TipRow {
                tip: "One step of the ring on the top bar's power reel, the same as one wheel notch. Forward brings the next item into the bar; the icons above it come round the far end."
                Button {
                    text: "◀ back"
                    onClicked: topPower.reel.step(-1)
                }
                Button {
                    text: "forward ▶"
                    onClicked: topPower.reel.step(1)
                }
                Button {
                    text: "Fire it"
                    onClicked: topPower.reel.activate()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "The sparks a turn throws, and the burst when something fires. Off is the honest comparison: the module has to read without them."
                CheckBox {
                    text: "Sparks"
                    checked: sharedStyle.particlesEnabled
                    onToggled: sharedStyle.particlesEnabled = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The wallpaper"
                blurb: "The real one, following the theme pair and mode. The stage is a SECTION of the screen at 1:1, so everything on it is the size it will be."
            }

            TipRow {
                tip: "1:1 shows the wallpaper's top-left corner at its own resolution -- the honest picture, because the bar is 40 real pixels. Fit scales the whole image into the stage, which is prettier and lies about scale."
                CheckBox {
                    text: "Fit instead of 1:1"
                    checked: win.wallpaperFit
                    onToggled: win.wallpaperFit = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            Label {
                Layout.fillWidth: true
                text: stageWall.fileName !== "" ? stageWall.fileName : "no wallpaper in shell.jsonc for this theme and mode"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                elide: Text.ElideMiddle
            }

            TipGroup {
                title: "State"
            }

            Label {
                Layout.fillWidth: true
                text: "in the bar:  power " + (topPower.reel.selectedItem ? topPower.reel.selectedItem.label : "—")
                    + "   ·   inhibit " + (topInhibit.reel.selectedItem ? topInhibit.reel.selectedItem.label : "—")
                    + "\nthePopup:  " + (engine.reelOpen ? engine.reelOwnerId : "closed")
                    + "\npopup asks for:  " + sharedStyle.thickness.toFixed(0) + " x "
                    + topPower.reel.popupLength.toFixed(0) + " (power), "
                    + topInhibit.reel.popupLength.toFixed(0) + " (inhibit)"
                    + "\nlast fired:  " + win.lastFired
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var reelGeom: [
        {
            label: "thickness",
            prop: "thickness",
            group: "The strip",
            blurb: "The strip across the axis. It is also the popup's width, so the engine's corner radius at half of it is what makes the far end a half circle.",
            tip: "How wide the strip is across the bar, and how wide thePopup is asked to be. Equal to the bar's thickness the module fills its cell exactly; under it, the strip is a narrower tongue hanging out of a wider bar.",
            val: 40,
            from: 20,
            to: 64,
            step: 1
        },
        {
            label: "bar cell",
            prop: "barCell",
            group: "The strip",
            tip: "The length of the cell the selected icon sits in. It has to be the BAR's thickness, on the Bar tab — the reel places the selected icon at half of this, so the two disagreeing is the icon sitting off-centre in its own cell, which is worth being able to see.",
            val: 40,
            from: 24,
            to: 64,
            step: 1
        },
        {
            label: "seam overlap",
            prop: "seamOverlap",
            group: "The strip",
            tip: "How far the bar's cell reaches past the bar's inner edge, into the popup. The two halves of the ring abut there, and at a fractional device scale their clip edges can fall either side of the same pixel row — which drops it, and a white hairline shows through an icon crossing the join. They overlap by a pixel instead; both draw the same ring at the same place, so the overlap itself cannot be seen. At 0 the hairline comes back at some magnifications.",
            val: 1,
            from: 0,
            to: 4,
            step: 1
        },
        {
            label: "cell pitch",
            prop: "cellPitch",
            group: "The strip",
            tip: "One icon to the next along the strip. Equal to the bar cell makes a perfectly regular column; a little under it packs the hanging part tighter than the bar without touching the icon in the bar.",
            val: 36,
            from: 20,
            to: 64,
            step: 1
        },
        {
            label: "icon size",
            prop: "iconPixelSize",
            group: "The strip",
            tip: "Glyph pixel size. Plain text: the shell's carved-icon component is still a concept and mangles a glyph this small, so these are drawn the way every other bar icon is today.",
            val: 21,
            from: 10,
            to: 40,
            step: 1
        },
        {
            label: "tail",
            prop: "tailFraction",
            group: "End of the strip",
            blurb: "Where the strip stops. At the last icon — not past it — so what ends the list is fog rather than an empty rounded stub.",
            tip: "How far past the LAST icon's centre the strip runs, in cells. This is the popup's whole length. Around 0.3 the icon just fits before the popup's own edge and the fog takes it from about half way down, which is what says the ring carries on. Past ~0.4 the popup grows an empty tail; below ~0.2 the popup's edge cuts the glyph instead of the fog.",
            val: 0.3,
            from: 0.1,
            to: 0.9,
            step: 0.01
        },
        {
            label: "wrap lead",
            prop: "wrapLead",
            group: "End of the strip",
            tip: "How far past the bar's outer edge an icon travels before it wraps to the far end, in cells. It has to be out of sight when it jumps: below ~0.5 the jump happens while the icon is still inside the bar's cell and reads as a flicker.",
            val: 0.6,
            from: 0.3,
            to: 1.5,
            step: 0.05
        }
    ]

    readonly property var reelMotion: [
        {
            label: "step ms",
            prop: "stepMs",
            group: "The turn",
            blurb: "One click of the ring. The strip's own opening and closing is NOT here: that is thePopup's growth, and the bar engine owns it.",
            tip: "How long one step of the ring takes. Long enough to see which icon went where, short enough that a five-step turn is not a journey.",
            val: 260,
            from: 80,
            to: 600,
            step: 10
        },
        {
            label: "overshoot",
            prop: "stepOvershoot",
            group: "The turn",
            tip: "0 is the shell's OutCubic — the reel slides and settles. Above 0 it overshoots by that much and comes back, which reads as a detent clicking home. Kept at 0 by default because the shell eases everything else this way.",
            val: 0,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "motion gain",
            prop: "motionGain",
            group: "The turn",
            tip: "How fast the fog at the bar's edge reaches full as the reel starts moving, per cell still to travel. It is read off the turn itself, not a separate timer, so the fog cannot outlive the motion it is hiding.",
            val: 2.4,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "press ms",
            prop: "pressMs",
            group: "Ink",
            tip: "How long the press colour takes. Shorter than hover — a press is an event, not a state.",
            val: 90,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "flash ms",
            prop: "flashMs",
            group: "Ink",
            tip: "How long the icon holds its own colour after it fires, on the way back to rest. With the spark burst this is the only thing that says the button did anything.",
            val: 420,
            from: 100,
            to: 1200,
            step: 20
        }
    ]

    readonly property var reelPopup: [
        {
            label: "open delay ms",
            prop: "openDelayMs",
            group: "thePopup",
            blurb: "When the ring is asked for and when it is given back. The growing, the curve out of the bar and the slide from one module to the next are the engine's own animation.",
            tip: "How long the pointer has to stay on the module before thePopup opens. Long enough that crossing the module on the way somewhere else does not open it; short enough that arriving deliberately feels immediate.",
            val: 90,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "close grace ms",
            prop: "closeGraceMs",
            group: "thePopup",
            tip: "How long the reel stays open after the pointer leaves both the bar cell and the popup. There is a frame on the way in where neither of them has the pointer; without a grace the reel closes under the pointer just as it arrives.",
            val: 160,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "width from",
            prop: "popupWidthFrom",
            group: "thePopup",
            tip: "The fraction of its final WIDTH thePopup starts at. The engine's own default is 0.5 — it inflates sideways as it comes out — and that is wrong for a strip: the content is anchored to the bar and must stand still while the popup grows, and a popup whose x and width are two animations makes the content jitter sideways by half a pixel whenever they disagree. 1 slides it out at full width. Drag it down to see the jitter it was.",
            val: 1.0,
            from: 0.1,
            to: 1.0,
            step: 0.05
        }
    ]

    readonly property var reelSwipe: [
        {
            label: "threshold",
            prop: "swipeThreshold",
            group: "Swipe",
            blurb: "A two-finger swipe arrives as a WHEEL on the axis it was made on -- see docs/contracts/gestures.md. These are the same shape and the same defaults as TabSelector's, so the reel resists like the rest of the shell.",
            tip: "Accumulated wheel units per step. A swipe is thousands of them; the failure mode is a flick of a few millimetres skipping two items, which on a power menu is the wrong thing armed. (A mouse is one icon per notch whatever this says.)",
            val: 700,
            from: 100,
            to: 3000,
            step: 50
        },
        {
            label: "max pull",
            prop: "swipeMaxPull",
            group: "Swipe",
            tip: "How far the ring is pulled out of its slot while the gesture is under way, in cells. Under half a cell on purpose: the pull must never complete a step by itself, or the detent has nothing left to snap.",
            val: 0.05,
            from: 0,
            to: 0.9,
            step: 0.01
        },
        {
            label: "pull taper",
            prop: "swipePullTaper",
            group: "Swipe",
            tip: "How sharply the pull tapers, as the exponent of 1-(1-t)^k. Most of the travel early and then resistance, so the distance left to the threshold reads as effort rather than as a slide. At 1 it is linear and the ring feels loose.",
            val: 3.0,
            from: 1,
            to: 8,
            step: 0.1
        },
        {
            label: "momentum rate",
            prop: "swipeMomentumRate",
            group: "Swipe",
            tip: "Accumulated units per second above which a swipe is carrying enough momentum to cross more than one item. Below it, one swipe is one icon and the rest of the gesture is dropped; above it, a flick keeps its remainder and carries through.",
            val: 600,
            from: 200,
            to: 8000,
            step: 100
        },
        {
            label: "cooldown ms",
            prop: "swipeCooldownMs",
            group: "Swipe",
            tip: "Minimum spacing between committed steps, so one long slow swipe steps once at a time rather than racing through the ring. A fast swipe skips it.",
            val: 100,
            from: 0,
            to: 1000,
            step: 20
        },
        {
            label: "return ms",
            prop: "swipeReturnMs",
            group: "Swipe",
            tip: "The spring the ring uses to come home when the gesture ends. A slight overshoot on the way reads as the spring releasing.",
            val: 320,
            from: 60,
            to: 900,
            step: 20
        },
        {
            label: "idle reset ms",
            prop: "swipeIdleResetMs",
            group: "Swipe",
            tip: "FALLBACK ONLY. A touchpad sends a zero-delta wheel event when the fingers lift, and that is what normally releases the pull. This exists so a device that never sends one cannot strand the ring mid-pull, which is why it is far longer than anyone holds still mid-gesture.",
            val: 6000,
            from: 500,
            to: 12000,
            step: 250
        }
    ]

    readonly property var reelFog: [
        {
            label: "far fog",
            prop: "fogLength",
            group: "Fog",
            blurb: "The colour-to-alpha fade at each end. It is what hides icons appearing and disappearing, and it is why a rectangular clip is invisible inside the popup's round end.",
            tip: "The fade at the far end, where the ring comes round. Permanent: the last icon dissolves into it rather than ending, which is what says there is more ring. It has to be deep enough to have finished before the popup's rounded corner starts, or the clip's straight edge shows inside the curve.",
            val: 30,
            from: 0,
            to: 70,
            step: 1
        },
        {
            label: "tip clearance",
            prop: "fogClearance",
            group: "Fog",
            tip: "How far short of the far TIP the fog is already solid. Zero, because above zero the fade reaches full a measurable distance inside the strip and against the rounded end that reads as the icon being CUT OFF by a straight line. Nothing needs it: a glyph is scaled to the outline's own half-width at its depth, so it can never reach past the shape however visible it still is.",
            val: 0,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "mask inset",
            prop: "maskInset",
            group: "Fog",
            tip: "How far INSIDE thePopup's outline the icons are cut. Tolerance on the mask, on purpose: an icon that close to the outline has all but gone into the fog, while one drawn a shade LATE is ink lying on the wallpaper. At 0 the cut sits exactly on the outline and the antialiasing of the two can disagree by a fraction of a pixel.",
            val: 1,
            from: 0,
            to: 6,
            step: 0.25
        },
        {
            label: "near fog",
            prop: "outerFogLength",
            group: "Fog",
            tip: "The fade at the bar's outer edge, where icons leave. It exists ONLY while the reel is turning — at rest the icon in the bar must be exact, so this band fades in with the motion and out with it.",
            val: 15,
            from: 0,
            to: 40,
            step: 1
        }
    ]

    readonly property var reelSparks: [
        {
            label: "per step",
            prop: "particleCount",
            group: "Sparks",
            blurb: "A turn throws a few sparks the way it is going. Sparse and subtle on purpose — this is a dash, not an effect.",
            tip: "How many sparks one step throws. Five is a dash; past about a dozen the strip starts to look like it is doing something rather than having been turned.",
            val: 5,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "speed",
            prop: "particleSpeed",
            group: "Sparks",
            tip: "How fast a spark leaves, in px/s along the strip, in the direction the reel is turning. This is the inertia: the sparks carry the movement on after the icons have stopped.",
            val: 150,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "scatter",
            prop: "particleScatter",
            group: "Sparks",
            tip: "Sideways spread, px/s. Zero is a clean jet along the strip; some scatter reads as dust being knocked loose.",
            val: 40,
            from: 0,
            to: 200,
            step: 5
        },
        {
            label: "lifetime ms",
            prop: "particleLifetimeMs",
            group: "Sparks",
            tip: "How long a spark lives. It should be gone by the time the step has settled, or the strip is still sparkling after it stopped moving.",
            val: 520,
            from: 100,
            to: 1500,
            step: 20
        },
        {
            label: "size start",
            prop: "particleSizeStart",
            group: "Sparks",
            tip: "Spark radius at birth, px. Under 2 at bar scale; a spark the size of a glyph stroke competes with the icons.",
            val: 1.6,
            from: 0.2,
            to: 5,
            step: 0.1
        },
        {
            label: "size end",
            prop: "particleSizeEnd",
            group: "Sparks",
            tip: "Radius at death. Shrinking as it fades is what makes it read as receding rather than as switching off.",
            val: 0.4,
            from: 0,
            to: 4,
            step: 0.1
        },
        {
            label: "drag",
            prop: "particleDrag",
            group: "Sparks",
            tip: "How fast a spark loses its speed. High drag makes the throw a short puff near the icon; low drag lets it run the length of the strip and into the fog.",
            val: 2.2,
            from: 0,
            to: 12,
            step: 0.1
        },
        {
            label: "burst",
            prop: "burstCount",
            group: "Sparks",
            tip: "How many sparks the activation throws, radially from the bar's end of the strip and in that item's own colour. With the icon's flash this is the only thing that says the button fired — past a dozen it stops being an acknowledgement and becomes an explosion.",
            val: 9,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "burst speed",
            prop: "burstSpeed",
            group: "Sparks",
            tip: "How fast the activation's sparks leave, px/s. Slower than a turn's sparks: the burst is a pulse at one place, not something being carried along.",
            val: 95,
            from: 0,
            to: 400,
            step: 5
        }
    ]

    // The bar engine's own two numbers. They are not the module's, but the
    // module is drawn by them: the popup's corner radius is what makes the
    // far end a half circle, and the bar's thickness is the cell.
    readonly property var engineParams: [
        {
            label: "bar thickness",
            prop: "thickness",
            group: "The bar",
            blurb: "The gooey engine's, not the reel's. Everything the module is sized by follows from these two.",
            tip: "How thick the bars are. The module's cell is one of these square, and the reel's `bar cell` is bound to it.",
            val: 40,
            from: 24,
            to: 72,
            step: 1
        },
        {
            label: "corner radius",
            prop: "maxR",
            group: "The bar",
            tip: "The engine's corner radius, for the bars and for thePopup. At half the strip's thickness or more the popup's far end is a half circle, which is what power.md asks for and what a strip this thin can carry.",
            val: 20,
            from: 0,
            to: 40,
            step: 1
        }
    ]

    // The reel paints in theme tokens and carries no palette of its own, so
    // these rows edit the THEME (themes/eva.json) and not the module.
    readonly property var reelColors: [
        {
            label: "surface",
            prop: "surface",
            group: "The strip",
            blurb: "The bars and thePopup are made of one surface, so a closed module is invisible against the bar and only what hangs out of it has an edge.",
            tip: "The bar's surface, thePopup's, and the colour the fog fades to at both ends.",
            val: "#EAEDF5"
        },
        {
            label: "icon ink",
            prop: "textPrimary",
            group: "The icons",
            blurb: "Position says which icon is selected, so it does not also get a colour: the one in the bar is simply the darker ink. Colour is the affordance, and it arrives with the pointer.",
            tip: "The icon in the bar — the selected one, the only one that can be fired.",
            val: "#5D5D5F"
        },
        {
            label: "hanging ink",
            prop: "textFaint",
            group: "The icons",
            tip: "The icons hanging out of the bar, and the sparks a turn throws: present, readable, and plainly not the one that is armed.",
            val: "#888888"
        },
        {
            label: "accent",
            prop: "accent",
            group: "Under the pointer",
            blurb: "What the pointer brings up. On an icon that would merely be selected, the accent; on the one that can actually be fired, ITS own colour.",
            tip: "The hover colour of an icon that is not selected — \"click and I come into the bar\".",
            val: "#4480F4"
        },
        {
            label: "error",
            prop: "error",
            group: "Under the pointer",
            tip: "Power off's own colour, on hover and in its activation flash.",
            val: "#EC0000"
        },
        {
            label: "warn",
            prop: "warn",
            group: "Under the pointer",
            tip: "Reboot's colour, and the hard inhibitor's.",
            val: "#FF6D12"
        },
        {
            label: "ok",
            prop: "ok",
            group: "Under the pointer",
            tip: "The normal inhibitor's colour: the machine is being kept awake and that is fine.",
            val: "#44C145"
        },
        {
            label: "cyan",
            prop: "catMultilib",
            group: "Under the pointer",
            tip: "Hibernate's colour, and the soft inhibitor's.",
            val: "#00BEC4"
        },
        {
            label: "violet",
            prop: "catFlatpak",
            group: "Under the pointer",
            tip: "Log out's colour.",
            val: "#C838C6"
        }
    ]
}
