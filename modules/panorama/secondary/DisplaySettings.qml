pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../data/PanoramaModel.js" as M
import "../data/PanoramaLayout.js" as L
import "../data/CastParse.js" as CP
import "../data/PanoramaStaging.js" as Staging
import "../popup"
import ".."

// =============================================================================
// DisplaySettings.qml -- the popup's secondary (the engine's content contract; the aerial pattern): one display's settings, every change
// STAGED through the service (stageSpec / stageSplit), the live brightness (DDC) the one thing that is not.
//
//   service        PanoramaService or PanoramaMock
//   secondaryKey   the display's NAME, assigned by the engine while this content is faded out (targetName: the same for a harness)
//   dismissed()    Escape: the popup closes this panel
//   naturalHeight  the content's own height (what the engine cannot move)
//
// A CAST display (a TV being streamed to: `out.cast`) is a normal display here, with a Cast block at the top (state and how long, Stop casting, the
// stream's figures (CastFigures), its quality: resolution, frame rate, bitrate, audio) and without the facts a headless output has none of
// (brightness, VRR, bit depth, colour, On) and without the ones that are the STREAM's, not a display's (Resolution, Refresh, Rotation: the
// stream has its own resolution and frame rate above, and a rotated headless output changes nothing a TV shows -- staged there, they asked
// for an Apply in the main popup that did nothing to the picture). A change of quality is a DRAFT until "Apply to stream": that saves it for the TV and restarts the
// stream ONCE.
//
// SIZE: this content never animates a height. A choice that appears or goes steps `implicitHeight` to its final value in one turn; the engine
// eases the box, the content stays laid out at the size it asked for, from the top (CLAUDE.md "The rest frame").
//
// The small one-of-few choices (rotation, refresh, scale, VRR, bit depth, colour) are segmented rows (ChoiceBar: the shell's TabSelector), two
// facts side by side where the width allows; a choice with many options (the resolutions, many refresh rates) is a Dropdown (a button with
// the shell's chevron opening a FloatingMenu); the sliders commit at rest (SideSlider). Scale carries the laptop's physical match as a note.
// =============================================================================
Item {
    id: root

    property var service: null
    property string fontFamily: "Inter"
    property PanoramaStyle style: PanoramaStyle {}
    property string targetName: ""
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)

    signal dismissed()

    readonly property string name: root.secondaryKey !== null && root.secondaryKey !== undefined && String(root.secondaryKey) !== "" ? String(root.secondaryKey) : root.targetName
    readonly property var displays: root.service && root.service.displays ? root.service.displays : []
    readonly property var out: root.displays.find(d => d.name === root.name) ?? null
    readonly property var laptop: root.displays.find(d => d.internal) ?? null
    readonly property var specs: root.service ? (root.service.staged ?? (root.service.plan ? root.service.plan.specs : {})) : {}
    readonly property var spec: root.specs[root.name] ?? null
    readonly property bool ok: !!root.out && !!root.spec
    readonly property var mode: root.ok ? (M.specMode(root.spec, root.out) ?? { w: root.out.width, h: root.out.height, r: root.out.refresh }) : { w: 0, h: 0, r: 0 }
    readonly property real scaleNow: root.ok ? M.specScale(root.spec, root.out, root.mode) : 1
    readonly property bool isLaptop: root.ok && root.out.internal
    readonly property bool mirrored: root.ok && !!root.spec.mirror
    // the machine's own display (the laptop's panel; any on a machine that has none) while no other is on: it cannot be switched off
    readonly property bool lastOn: (root.isLaptop || !root.laptop) && !root.othersOn
    readonly property bool othersOn: root.ok && Object.keys(root.specs).some(n => n !== root.name && root.specs[n].enabled && !root.specs[n].mirror)
    readonly property bool hdrNow: root.ok && root.spec.cm === "hdr"

    // ---- cast ----
    readonly property bool isCast: root.ok && root.out.cast === true
    // Resolution, Refresh, Rotation: a real display's rows. A cast has the stream's own resolution and frame rate, and nothing to rotate
    readonly property bool displayRows: root.ok && !root.mirrored && !root.isCast
    readonly property var castStored: root.isCast && root.service ? root.service.castQualityOf(root.name) : Staging.CAST_QUALITY
    property var qDraft: null
    readonly property var qNow: root.qDraft !== null ? root.qDraft : root.castStored
    readonly property bool qDirty: root.qDraft !== null && JSON.stringify(root.qDraft) !== JSON.stringify(root.castStored)
    readonly property bool castBusyNow: !!root.service && root.isCast && root.service.castPhase !== "idle" && root.service.castPhase !== "streaming"
    readonly property string castLine: {
        const s = root.service;
        if (!s || !root.isCast)
            return "";
        if (s.castPhase === "streaming" && s.castState === "streaming") {
            const m = s.castMode;
            return "Casting" + (m ? " · " + m.width + " × " + m.height + " @ " + m.fps + " fps" : "") + (root.mirrored ? " · the laptop's screen" : "");
        }
        const t = s.castStatusText(s.castActiveDevice);
        return t !== "" ? t : "Not casting";
    }
    function setQ(k: string, v: var): void {
        const q = Object.assign({}, root.qNow);
        q[k] = v;
        root.qDraft = q;
    }
    function applyQ(): void {
        if (!root.service || !root.qDirty)
            return;
        const q = root.qDraft;
        root.qDraft = null;
        root.service.castApplyQuality(q);
    }

    readonly property bool menuOpen: resolution.open || refreshMenu.open || scaleMenu.open
    function _closeMenus(): bool {
        const was = root.menuOpen;
        resolution.close();
        refreshMenu.close();
        scaleMenu.close();
        return was;
    }
    // Escape (the popup asks it first): an open menu closes; else false, the popup's Escape rule decides
    function handleEscape(): bool {
        return root._closeMenus();
    }

    function patch(p: var): void {
        if (root.service && root.ok)
            root.service.stageSpec(root.name, p);
    }

    // ---- the lists, from the display's modes -------------------------------------------------------------------------------------------
    readonly property var sizes: {
        const seen = {}, res = [];
        if (!root.ok)
            return res;
        for (const m of root.out.modes) {
            const k = m.w + "x" + m.h;
            if (!seen[k]) { seen[k] = true; res.push({ key: k, w: m.w, h: m.h, label: m.w + " × " + m.h }); }
        }
        res.sort((a, b) => b.w * b.h - a.w * a.h);
        return res;
    }
    readonly property string sizeKey: root.mode.w + "x" + root.mode.h
    readonly property var rates: {
        const res = [];
        if (!root.ok)
            return res;
        for (const m of root.out.modes)
            if (m.w === root.mode.w && m.h === root.mode.h && !res.some(r => Math.abs(r.r - m.r) < 0.5))
                res.push({ r: m.r, key: String(Math.round(m.r)), label: (Math.round(m.r * 100) / 100) + " Hz" });
        res.sort((a, b) => b.r - a.r);
        return res;
    }
    readonly property var scaleOptions: {
        if (!root.ok)
            return [];
        const phys = M.physicalScale(root.out, root.mode.w, root.mode.h, root.laptop);
        const list = L.scaleShown(M.scaleChoices(root.mode.w, root.mode.h), root.scaleNow, phys);
        return list.map(v => ({ key: String(Math.round(v * 1000)), label: (Math.round(v * 1000) / 1000) + "×",
                                mark: typeof phys === "number" && Math.abs(phys - v) < 0.0005 }));
    }
    readonly property string scalePhysText: {
        const m = root.scaleOptions.find(o => o.mark);
        return m ? m.label + " matches the laptop" : "";
    }
    readonly property var colourOptions: {
        const res = [{ key: "srgb", label: "sRGB" }];
        if (root.ok && root.out.bt2020) res.push({ key: "wide", label: "Wide" });
        if (root.ok && root.out.hdr) res.push({ key: "hdr", label: "HDR" });
        return res;
    }

    function pickSize(key: string): void {
        const s = root.sizes.find(x => x.key === key);
        if (!s) return;
        let best = null;
        for (const m of root.out.modes)
            if (m.w === s.w && m.h === s.h && (!best || Math.abs(m.r - root.mode.r) < Math.abs(best.r - root.mode.r))) best = m;
        if (best) root.patch({ mode: M.modeString(best.w, best.h, best.r) });
    }
    function pickRate(key: string): void {
        const r = root.rates.find(x => x.key === key);
        if (r) root.patch({ mode: M.modeString(root.mode.w, root.mode.h, r.r) });
    }

    // ---- brightness (a monitor's own over DDC, the laptop panel's backlight): one read through the service
    readonly property var brightness: {
        const s = root.service;
        void (s ? s.brightnessRev : 0);
        const b = s && root.ok ? s.brightnessOf(root.name) : null;
        if (!b)
            return { capable: false, value: 0, known: false, pending: false };
        return { capable: !!b.capable, value: Math.max(0, Math.min(1, Number(b.value))), known: Number(b.value) >= 0, pending: !!b.pending };
    }
    function setBrightness(v: real): void {
        if (!root.service)
            return;
        // the slider commits at rest (SideSlider), so the value is written now, not 250 ms on
        root.service.setBrightness(root.name, v);
        root.service.commitBrightness(root.name);
    }

    // ---- the workspaces: ONE read, the service's `splitIdents` (staged if staged, else the resolved split)
    function _wsHere(ws: string): bool {
        const s = root.service;
        return !!s && root.ok && !!s.splitIdents && s.splitIdents[ws] === root.out.ident;
    }
    readonly property bool canReset: !!root.service && root.displays.length > 1

    // ---- size ------------------------------------------------------------------------------------------------------------------------------
    readonly property real _pad: root.style.padding
    readonly property real _g: root.style.sideGroupGap
    implicitWidth: root.style.sideWidth
    readonly property real naturalHeight: Math.ceil(2 * root._pad + head.height + col.height)
    implicitHeight: root.naturalHeight

    Item {
        id: head
        x: root._pad
        y: root._pad
        width: root.width - 2 * root._pad
        height: 38
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.ok ? root.out.label : ""
            color: Theme.textPrimary
            font.family: root.fontFamily
            font.pixelSize: root.style.titleSize
            font.bold: true
        }
        Text {
            y: 22
            text: root.ok ? root.out.name + (root.out.physW > 0 ? "  ·  " + Math.round(Math.sqrt(root.out.physW * root.out.physW + root.out.physH * root.out.physH) / 25.4 * 10) / 10 + "″" : "") : ""
            color: Theme.textFaint
            font.family: root.fontFamily
            font.pixelSize: root.style.figureSize
        }
    }

    FactGrid {
        id: col
        gap: root._g
        x: root._pad
        y: root._pad + head.height
        width: root.width - 2 * root._pad

        // the cast: state and stop, then the stream's quality
        Captioned {
            gap: 4
            shown: root.isCast
            title: "Cast"
            note: root.isCast && root.service ? CP.ageText(root.service.castStats) : ""
            captionGap: root.style.captionGap
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            Item {
                width: parent.width
                height: root.style.buttonHeight
                Text {
                    objectName: "castLine"
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - stopBtn.width - root.style.castConfirmGap
                    elide: Text.ElideRight
                    text: root.castLine
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                }
                PanoButton {
                    id: stopBtn
                    objectName: "stopCasting"
                    anchors.right: parent.right
                    text: "Stop casting"
                    ground: Theme.surface
                    fontFamily: root.fontFamily
                    height: root.style.buttonHeight
                    onClicked: if (root.service) root.service.castStop()
                }
            }
            Loader {
                id: castFigures
                // a Loader's item is not a child the caption's height hears before it has rows: it stands at the top until then
                y: castFigures.height > 0 ? root.style.buttonHeight + root.style.captionGap : 0
                width: parent.width
                active: root.isCast && !!root.service
                sourceComponent: CastFigures {
                    objectName: "castFigures"
                    service: root.service
                    fontFamily: root.fontFamily
                    figureSize: root.style.figureSize
                    rowHeight: root.style.castFigureRow
                    columnGap: root.style.sideGroupGap
                }
            }
        }
        Captioned {
            gap: root._g
            shown: root.isCast
            title: "Stream resolution"
            captionGap: root.style.captionGap
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                objectName: "castRes"
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "1280x720", label: "1280×720" }, { key: "1920x1080", label: "1920×1080" }, { key: "2560x1440", label: "2560×1440" },
                          { key: "3840x2160", label: "3840×2160" }]
                current: root.qNow.res
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.setQ("res", k)
            }
        }
        Captioned {
            half: true
            gap: root._g
            shown: root.isCast
            title: "Frame rate"
            captionGap: root.style.captionGap
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                objectName: "castFps"
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "30", label: "30" }, { key: "60", label: "60" }]
                current: String(root.qNow.fps)
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.setQ("fps", Number(k))
            }
        }
        Captioned {
            half: true
            gap: root._g
            shown: root.isCast
            title: "Bitrate"
            captionGap: root.style.captionGap
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                objectName: "castBitrate"
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "4M", label: "4M" }, { key: "8M", label: "8M" }, { key: "16M", label: "16M" }]
                current: root.qNow.bitrate
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.setQ("bitrate", k)
            }
        }
        Captioned {
            gap: root._g
            shown: root.isCast
            fontFamily: root.fontFamily
            Item {
                width: parent.width
                height: root.style.sideRow
                Text {
                    text: "Send sound"
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                }
                GrooveToggle {
                    objectName: "castAudio"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.qNow.audio !== false
                    surfaceColor: Theme.surface
                    onToggled: c => root.setQ("audio", c)
                }
            }
        }
        Captioned {
            gap: root._g
            shown: root.isCast && root.qDirty
            fontFamily: root.fontFamily
            Item {
                width: parent.width
                height: root.style.buttonHeight
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Restarts the stream once."
                    color: Theme.textMuted
                    font.family: root.fontFamily
                    font.pixelSize: root.style.figureSize
                }
                PanoButton {
                    objectName: "applyToStream"
                    anchors.right: parent.right
                    text: "Apply to stream"
                    accent: true
                    ground: Theme.surface
                    fontFamily: root.fontFamily
                    height: root.style.buttonHeight
                    onClicked: root.applyQ()
                }
            }
        }

        // on / off, mirror
        Captioned {
                gap: 4
            shown: root.ok && !root.isCast
            fontFamily: root.fontFamily
            Item {
                width: parent.width
                height: root.style.sideRow
                Text {
                    text: "On"
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                }
                GrooveToggle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.ok && root.spec.enabled
                    opacity: root.lastOn ? 0.4 : 1
                    surfaceColor: Theme.surface
                    onToggled: c => { if (!root.lastOn) root.patch({ enabled: c }); }
                }
            }
        }
        Captioned {
                gap: root.isCast ? root._g : 0
            shown: root.ok && !root.isLaptop && !!root.laptop && !!root.specs[root.laptop.name] && root.specs[root.laptop.name].enabled
            fontFamily: root.fontFamily
            Item {
                width: parent.width
                height: root.style.sideRow
                Text {
                    text: "Mirror the laptop"
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                }
                GrooveToggle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.mirrored
                    surfaceColor: Theme.surface
                    // a cast's mirror is no trial: the stream is restarted in its other shape (a mirror has no display of its own)
                    onToggled: c => {
                        if (root.isCast && root.service)
                            root.service.castSetMirror(c);
                        else
                            root.patch({ mirror: c });
                    }
                }
            }
        }

        // resolution: a dropdown
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.displayRows
            title: "Resolution"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            Dropdown {
                id: resolution
                objectName: "resolutionDropdown"
                width: parent.width
                height: root.style.segHeight
                style: root.style
                fontFamily: root.fontFamily
                overlay: overlayLayer
                options: root.sizes
                current: root.sizeKey
                onChosen: k => root.pickSize(k)
            }
        }

        // refresh | rotation
        Captioned {
            id: refBlock
            half: true
            gap: root._g
            captionGap: root.style.captionGap
            shown: root.displayRows
            title: "Refresh"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                visible: root.rates.length <= 3
                width: parent.width
                height: root.style.segHeight
                options: root.rates
                current: String(Math.round(root.mode.r))
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.pickRate(k)
            }
            Dropdown {
                id: refreshMenu
                visible: root.rates.length > 3
                width: parent.width
                height: root.style.segHeight
                style: root.style
                fontFamily: root.fontFamily
                overlay: overlayLayer
                options: root.rates
                current: String(Math.round(root.mode.r))
                onChosen: k => root.pickRate(k)
            }
        }
        Captioned {
            id: rotBlock
            half: true
            gap: root._g
            captionGap: root.style.captionGap
            shown: root.displayRows
            title: "Rotation"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "0", label: "0°" }, { key: "1", label: "90°" }, { key: "2", label: "180°" }, { key: "3", label: "270°" }]
                current: String(root.ok ? root.spec.transform : 0)
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.patch({ transform: Number(k) })
            }
        }

        // scale: tabs, or a dropdown when there are many; the laptop's physical match is the caption's note
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored
            title: "Scale"
            note: root.scalePhysText
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                visible: root.scaleOptions.length <= root.style.segMaxTabs
                width: parent.width
                height: root.style.segHeight
                options: root.scaleOptions
                current: String(Math.round(root.scaleNow * 1000))
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.patch({ scale: Number(k) / 1000 })
            }
            Dropdown {
                id: scaleMenu
                visible: root.scaleOptions.length > root.style.segMaxTabs
                width: parent.width
                height: root.style.segHeight
                style: root.style
                fontFamily: root.fontFamily
                overlay: overlayLayer
                options: root.scaleOptions
                current: String(Math.round(root.scaleNow * 1000))
                onChosen: k => root.patch({ scale: Number(k) / 1000 })
            }
        }

        // VRR | bit depth
        Captioned {
            id: vrr
            half: true
            gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored && root.out.vrrCapable
            title: "Variable refresh"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "0", label: "Off" }, { key: "1", label: "On" }, { key: "2", label: "Full" }]
                current: String(root.ok ? root.spec.vrr : 0)
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.patch({ vrr: Number(k) })
            }
        }
        Captioned {
            id: depth
            half: true
            gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored && !root.isCast
            title: "Bit depth"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                width: parent.width
                height: root.style.segHeight
                options: [{ key: "8", label: "8 bit" }, { key: "10", label: "10 bit" }]
                current: String(root.ok ? root.spec.bitdepth : 8)
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.patch({ bitdepth: Number(k) })
            }
        }

        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored && root.colourOptions.length > 1
            title: "Colour"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            ChoiceField {
                width: parent.width
                height: root.style.segHeight
                options: root.colourOptions
                current: root.ok ? (root.spec.cm === "edid" || root.spec.cm === "hdredid" ? "srgb" : root.spec.cm) : "srgb"
                fontFamily: root.fontFamily
                fontSize: root.style.figureSize
                onChosen: k => root.patch({ cm: k })
            }
        }
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored && root.hdrNow
            title: "SDR brightness"
            note: sdrBright.figure
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            SideSlider {
                id: sdrBright
                width: parent.width
                from: 0.5
                to: 2
                step: 0.05
                hostValue: root.ok ? (root.spec.sdrbrightness - 0.5) / 1.5 : 0.33
                onCommitted: v => root.patch({ sdrbrightness: Math.round((0.5 + v * 1.5) * 20) / 20 })
            }
        }
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && !root.mirrored && root.hdrNow
            title: "SDR saturation"
            note: sdrSat.figure
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            SideSlider {
                id: sdrSat
                width: parent.width
                from: 0.5
                to: 2
                step: 0.05
                hostValue: root.ok ? (root.spec.sdrsaturation - 0.5) / 1.5 : 0.33
                onCommitted: v => root.patch({ sdrsaturation: Math.round((0.5 + v * 1.5) * 20) / 20 })
            }
        }

        // the display's own brightness: live, not staged (a monitor's DDC, the laptop's panel where the service can), the figure muted while a write is out
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            shown: root.ok && root.brightness.capable
            title: "Brightness"
            note: brightnessSlider.figure
            noteMuted: brightnessSlider.figureMuted
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            SideSlider {
                id: brightnessSlider
                objectName: "brightnessSlider"
                width: parent.width
                unit: "%"
                hostValue: root.brightness.value
                pending: root.brightness.pending
                known: root.brightness.known
                onCommitted: v => root.setBrightness(v)
            }
        }

        // the workspaces this display holds: plain toggles
        Captioned {
                gap: root._g
            captionGap: root.style.captionGap
            // (one display on a machine with no panel of its own holds them all: nothing to choose)
            shown: root.ok && root.spec.enabled && !root.mirrored && (!!root.laptop || root.othersOn)
            title: "Workspaces"
            fontFamily: root.fontFamily
            figureSize: root.style.figureSize
            Row {
                spacing: root.style.chipGapSide
                Repeater {
                    model: 4
                    delegate: PanoButton {
                        id: chip
                        required property int index
                        readonly property string ws: String(chip.index + 1)
                        text: chip.ws
                        width: Math.floor((col.width - 3 * root.style.chipGapSide) / 4)
                        height: root.style.buttonHeight
                        ground: Theme.surface
                        accent: root.service ? root._wsHere(chip.ws) : false
                        fontFamily: root.fontFamily
                        onClicked: if (root.service && root.ok) root.service.stageSplit(chip.ws, root.out.ident)
                    }
                }
            }
        }

        // the foot: the one quiet action
        Captioned {
                gap: root._g
            shown: root.ok && root.canReset
            fontFamily: root.fontFamily
            Item {
                id: reset
                objectName: "resetArrangement"
                width: parent.width
                height: root.style.buttonHeight
                property real _hover: resetArea.containsMouse ? 1 : 0
                Behavior on _hover {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Reset arrangement"
                    color: Mix.c(Theme.textFaint, Theme.accent, reset._hover)
                    font.family: root.fontFamily
                    font.pixelSize: root.style.figureSize
                }
                MouseArea {
                    id: resetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.service.stageReset()
                }
            }
        }
    }

    // floating things (the dropdown menus): above everything, never clipped by a block
    Item {
        id: overlayLayer
        objectName: "sideOverlay"
        anchors.fill: parent
        z: 100
    }
}
