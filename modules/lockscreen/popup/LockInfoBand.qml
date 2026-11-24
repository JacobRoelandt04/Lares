pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"
import "../../weather/data/WeatherModel.js" as WM
import "../../screentime/data/ScreentimeModel.js" as STM

// =============================================================================
// LockInfoBand.qml -- what the machine would tell you at a glance: the battery,
// the weather now, the updates waiting, today's screen time. A carved band of up
// to four cells.
//
// EACH CELL IS ITS SOURCE'S, and a cell whose source is null is gone: the
// cells that are up re-lay out (their x eases, 260 ms OutCubic), and a band
// with no cell at all is not there -- `implicitHeight` is 0, the popup's stack
// closes over it.
//
// SLICES BY WHAT EACH CELL NEEDS (four equal slices of
// 440 would cut the battery and the updates). A cell's slice is its block plus the
// padding on both sides; the room left over is shared equally, so every block
// sits centred between its two walls (a divider or the band's end) and the
// dividers stand halfway between blocks. Where the band is narrower than the
// blocks need, every block shrinks by the same factor and its texts elide.
// ONE layout, `_layout`, places the cells AND the dividers (two bindings that
// derived from each other would see two generations mid-change); a cell that is
// not up keeps a place where it would stand, so it fades out where it was.
//
//   battery   a small carved battery, "82%", and what is left ("3h 5m left",
//             "45m to full", "Full") in the shell's one duration format (the
//             screentime module's DUR, `STM.fmt`). `battery` is a BatteryData (or
//             a mock of it); no status (no battery on this machine) = no cell
//   weather   the carved WeatherGlyph, the temperature in the weather module's
//             own units, the condition in its own words. `weather` is the
//             WeatherService (or its mock): its `model.current` and
//             `config.units`
//   updates   "205 updates" over a bar split by repo in the update popup's own
//             colours (core, extra, multilib, aur, flatpak), the shell's one
//             category palette. `updates` is the AvailableUpdatesService (or a
//             mock): `totalCount` and `categories` [{ key, count }]
//   screen    today's screen time over the session the lock just ended ("5h 3m"
//             / "session 1h 12m"), in the screentime module's own words (DUR).
//             `screentime` is the ScreentimeService (or its mock): its `state`.
//             Locked is away, so nothing here moves while it is shown
//
// FIGURES NEVER JITTER. Each cell is a block of a FIXED width -- the widest
// text it can show, measured -- centred in its slice; the text inside is
// left-aligned in its own slot, so a percentage turning "9%" -> "10%" or a
// remaining time turning "9h 59m" -> "10h 0m" moves nothing.
//
// A cell never outgrows its slot: its texts elide inside the block's width
// (a narrow popup shortens words, it never overlaps a neighbour).
//
// No pointer input: nothing here is a link on the lock. A repeater's model
// carries facts only (the segments' keys and widths); the delegate resolves
// the colour.
// =============================================================================
Item {
    id: root

    property var battery: null
    property var weather: null
    property var updates: null
    property var screentime: null
    property string fontFamily: "Audiowide"
    property real renderScale: 1

    property real bandHeight: 56
    property real radius: 14
    property real padding: 12
    property real figureSize: 13
    property real lineSize: 10
    property real lineGap: 2
    property real glyphSize: 28
    property real batteryWidth: 28
    property real batteryHeight: 15
    property real barWidth: 88
    property real barHeight: 4
    property int slideMs: 260
    property int fadeMs: 160

    // Which cells there are and in which order.
    property var order: ["battery", "weather", "updates", "screen"]
    readonly property var _keys: ["battery", "weather", "updates", "screen"]
    function _wanted(key: string): bool {
        return root.order.indexOf(key) >= 0;
    }

    // ---- what each cell knows -------------------------------------------------
    readonly property bool hasBattery: root._wanted("battery") && !!root.battery && String(root.battery.status).length > 0
    readonly property var _cur: root.weather && root.weather.model ? root.weather.model.current : null
    readonly property bool hasWeather: root._wanted("weather") && !!root.weather && !!root._cur
    readonly property bool hasUpdates: root._wanted("updates") && !!root.updates && root.updates.totalCount !== undefined
    readonly property var _st: root.screentime ? root.screentime.state : null
    readonly property bool hasScreen: root._wanted("screen") && !!root._st
    readonly property int _count: (root.hasBattery ? 1 : 0) + (root.hasWeather ? 1 : 0) + (root.hasUpdates ? 1 : 0)
                                  + (root.hasScreen ? 1 : 0)

    implicitWidth: 560
    implicitHeight: root._count > 0 ? root.bandHeight : 0
    visible: root._count > 0

    // ---- the layout ------------------------------------------------------------
    // Per cell, in the band's order: { x, w } of its slot (the block, centred in
    // its slice), and `walls`: the x of each divider between two cells that are up.
    readonly property var _layout: {
        const all = { battery: [root.hasBattery, root._batteryBlock], weather: [root.hasWeather, root._weatherBlock],
                      updates: [root.hasUpdates, root._updatesText], screen: [root.hasScreen, root._screenText] };
        const keys = root._keys.filter(k => root._wanted(k)).sort((a, b) => root.order.indexOf(a) - root.order.indexOf(b))
            .concat(root._keys.filter(k => !root._wanted(k)));
        const up = keys.map(k => all[k][0]);
        const block = keys.map(k => all[k][1]);
        const pad = root.padding;
        let need = 0, n = 0;
        for (let i = 0; i < 4; i++) {
            if (up[i]) {
                need += block[i];
                n++;
            }
        }
        // shrink every block by one factor when they do not fit; else share the spare room
        const fit = n > 0 && need > 0 ? Math.min(1, Math.max(0, root.width - 2 * pad * n) / need) : 1;
        const spare = n > 0 ? Math.max(0, root.width - 2 * pad * n - need) / n : 0;
        const out = { walls: [] };
        let left = 0;
        for (let i = 0; i < 4; i++) {
            const w = Math.floor(block[i] * fit);
            if (up[i]) {
                const slice = w + 2 * pad + spare;
                out[keys[i]] = { x: Math.round(left + (slice - w) / 2), w: w };
                left += slice;
                if (out.walls.length < n - 1)
                    out.walls.push(Math.round(left));
            } else {
                // not up: where it would stand, so it fades out in place
                out[keys[i]] = { x: Math.round(left - w / 2), w: w };
            }
        }
        return out;
    }

    // ---- texts ---------------------------------------------------------------
    readonly property string batteryFigure: root.hasBattery ? Math.round(root.battery.percent) + "%" : ""
    readonly property string batteryLine: {
        if (!root.hasBattery)
            return "";
        const b = root.battery;
        if (b.isFull)
            return "Full";
        const t = b.estimatedTimeSec;
        if (b.isCharging)
            return t > 0 ? STM.fmt(t) + " to full" : "Charging";
        return t > 0 ? STM.fmt(t) + " left" : "On battery";
    }
    readonly property var _fmt: WM.format(root.weather && root.weather.config ? root.weather.config.units : ({}))
    readonly property string weatherFigure: root.hasWeather ? root._fmt.temp(root._cur.temp) : ""
    readonly property string weatherLine: root.hasWeather
        ? WM.conditionText(root._cur.kind, root._cur.intensity, root._cur.night, root._cur.shower, root._cur.code) : ""
    readonly property int updatesTotal: root.hasUpdates ? root.updates.totalCount : 0
    // Today's closed total (locked is away: nothing open to add) and the
    // session the lock ended; while the daemon still counts one, that one.
    readonly property string screenFigure: root.hasScreen && root._st.today ? STM.fmt(root._st.today.total) : ""
    readonly property string screenLine: {
        if (!root.hasScreen)
            return "";
        const s = root._st.session ?? root._st.lastSession;
        return s ? "session " + STM.fmt(s.active) : "today";
    }
    readonly property string updatesFigure: root.updatesTotal > 0 ? root.updatesTotal + (root.updatesTotal === 1 ? " update" : " updates") : "Up to date"

    // The segments of the updates bar: keys and pixel widths, never colours.
    readonly property var _segs: {
        const cats = root.hasUpdates && root.updates.categories ? root.updates.categories : [];
        const total = Math.max(1, root.updatesTotal);
        const gap = 2;
        const usable = root._barW - gap * Math.max(0, cats.length - 1);
        const out = [];
        let x = 0;
        for (let i = 0; i < cats.length; i++) {
            const w = Math.max(3, Math.round(usable * cats[i].count / total));
            out.push({ key: cats[i].key, x: x, w: w });
            x += w + gap;
        }
        return out;
    }
    function _catColor(key) {
        switch (key) {
        case "core": return Theme.catCore;
        case "extra": return Theme.catExtra;
        case "multilib": return Theme.catMultilib;
        case "aur": return Theme.catAur;
        case "flatpak": return Theme.catFlatpak;
        }
        return Theme.catCore;
    }

    // ---- measured slots -------------------------------------------------------
    FontMetrics {
        id: figFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
        font.bold: true
    }
    FontMetrics {
        id: lineFm
        font.family: root.fontFamily
        font.pixelSize: root.lineSize
    }
    function _fig(s) {
        const f = figFm.font;
        return Math.ceil(figFm.advanceWidth(s));
    }
    function _line(s) {
        const f = lineFm.font;
        return Math.ceil(lineFm.advanceWidth(s));
    }
    readonly property real _textH: Math.ceil(figFm.height) + root.lineGap + Math.ceil(lineFm.height)
    readonly property real _batteryText: Math.max(root._fig("100%"), root._line("88h 88m left"), root._line("88h 88m to full"),
                                                  root._line("Charging"), root._line("On battery"))
    readonly property real _batteryBlock: root.batteryWidth + 3 + root._textGap + root._batteryText
    readonly property real _weatherText: {
        const f = lineFm.font;
        let w = root._fig("-88°");
        for (const s of WM.conditionTexts())
            w = Math.max(w, root._line(s));
        return w;
    }
    readonly property real _updatesText: Math.max(root._fig("1000 updates"), root.barWidth)
    readonly property real _screenText: Math.max(root._fig("88h 88m"), root._line("session 88h 88m"))
    readonly property real _weatherBlock: root.glyphSize + root._textGap + root._weatherText
    readonly property real _textGap: 8
    // The bar never outgrows its slot.
    readonly property real _barW: Math.min(root.barWidth, root._layout.updates.w)

    // ---- the carve -----------------------------------------------------------
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    // Dividers between the cells that are up.
    Repeater {
        model: 3
        delegate: Rectangle {
            id: rule
            required property int index
            readonly property bool on: rule.index < root._layout.walls.length
            visible: rule.on
            x: (rule.on ? root._layout.walls[rule.index] : (root._layout.walls.length > 0 ? root._layout.walls[root._layout.walls.length - 1] : root.width / 2)) - 1
            y: Math.round(root.height * 0.25)
            width: 1
            height: Math.round(root.height * 0.5)
            color: Theme.border
            Behavior on x {
                NumberAnimation {
                    duration: root.slideMs
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    // A cell: presence, a block of fixed width centred in its slice (`_layout`).
    component Cell: Item {
        id: cell
        property bool present: false
        property var slot: ({ x: 0, w: 0 })
        readonly property real slotW: cell.slot.w
        property real _pf: cell.present ? 1 : 0
        Behavior on _pf {
            NumberAnimation {
                duration: root.fadeMs
                easing.type: Easing.OutCubic
            }
        }
        visible: cell._pf > 0
        opacity: cell._pf
        width: cell.slotW
        height: root._textH
        y: Math.round((root.height - cell.height) / 2)
        x: cell.slot.x
        Behavior on x {
            NumberAnimation {
                duration: root.slideMs
                easing.type: Easing.OutCubic
            }
        }
    }

    // ---- battery ----------------------------------------------------------------
    Cell {
        id: batteryCell
        present: root.hasBattery
        slot: root._layout.battery

        readonly property real percent: root.hasBattery ? root.battery.percent : 0
        // the pack the charge limit leaves (the adapter's; a BatteryData has none): the cell fills to it and its lines stand in proportion, as the bar's track
        readonly property real target: root.hasBattery && root.battery.targetPercent > 0 ? root.battery.targetPercent : 100
        readonly property color fill: {
            if (batteryCell.percent <= Math.round(0.15 * batteryCell.target))
                return Theme.batteryLow;
            if (batteryCell.percent >= 0.95 * batteryCell.target || (root.hasBattery && root.battery.isCharging))
                return Theme.batteryCharge;
            return Theme.textPrimary;
        }
        Item {
            id: cellIcon
            width: root.batteryWidth + 3
            height: root.batteryHeight
            y: Math.round((batteryCell.height - height) / 2)
            ShadowBox {
                id: cellBody
                width: root.batteryWidth
                height: root.batteryHeight
                baseRadius: 4
                surfaceColor: Theme.listBox
                backgroundColor: Theme.listBox
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 2
                Rectangle {
                    x: 3
                    y: 3
                    width: Math.max(0, Math.round((cellBody.width - 6) * Math.max(0, Math.min(batteryCell.target, batteryCell.percent)) / batteryCell.target))
                    height: cellBody.height - 6
                    radius: 2
                    color: batteryCell.fill
                }
            }
            Rectangle {
                x: root.batteryWidth
                y: Math.round((root.batteryHeight - height) / 2)
                width: 3
                height: 7
                radius: 1.5
                color: Theme.border
            }
        }
        Column {
            x: cellIcon.width + root._textGap
            y: 0
            spacing: root.lineGap
            Text {
                width: Math.max(0, batteryCell.width - cellIcon.width - root._textGap)
                elide: Text.ElideRight
                text: root.batteryFigure
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                font.bold: true
            }
            Text {
                width: Math.max(0, batteryCell.width - cellIcon.width - root._textGap)
                elide: Text.ElideRight
                text: root.batteryLine
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.lineSize
            }
        }
    }

    // ---- weather ---------------------------------------------------------------
    Cell {
        id: weatherCell
        present: root.hasWeather
        slot: root._layout.weather

        WeatherGlyph {
            id: glyph
            size: root.glyphSize
            renderScale: root.renderScale
            y: Math.round((weatherCell.height - height) / 2)
            kind: root.hasWeather && root._cur.kind ? root._cur.kind : "clear"
            intensity: root.hasWeather && root._cur.intensity !== undefined ? root._cur.intensity : 1
            night: root.hasWeather ? !!root._cur.night : false
            shower: root.hasWeather ? !!root._cur.shower : false
        }
        Column {
            x: root.glyphSize + root._textGap
            spacing: root.lineGap
            Text {
                width: Math.max(0, weatherCell.width - root.glyphSize - root._textGap)
                elide: Text.ElideRight
                text: root.weatherFigure
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                font.bold: true
            }
            Text {
                width: Math.max(0, weatherCell.width - root.glyphSize - root._textGap)
                elide: Text.ElideRight
                text: root.weatherLine
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.lineSize
            }
        }
    }

    // ---- updates ---------------------------------------------------------------
    Cell {
        id: updatesCell
        present: root.hasUpdates
        slot: root._layout.updates

        Column {
            spacing: root.lineGap
            Text {
                width: updatesCell.width
                elide: Text.ElideRight
                text: root.updatesFigure
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                font.bold: true
            }
            Item {
                width: root._barW
                height: Math.ceil(lineFm.height)
                Repeater {
                    model: root._segs
                    delegate: Rectangle {
                        id: seg
                        required property var modelData
                        x: seg.modelData.x
                        y: Math.round((parent.height - root.barHeight) / 2)
                        width: seg.modelData.w
                        height: root.barHeight
                        radius: root.barHeight / 2
                        color: root._catColor(seg.modelData.key)
                    }
                }
            }
        }
    }

    // ---- screen time -------------------------------------------------------------
    Cell {
        id: screenCell
        present: root.hasScreen
        slot: root._layout.screen

        Column {
            spacing: root.lineGap
            Text {
                width: screenCell.width
                elide: Text.ElideRight
                text: root.screenFigure
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                font.bold: true
            }
            Text {
                width: screenCell.width
                elide: Text.ElideRight
                text: root.screenLine
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.lineSize
            }
        }
    }
}
