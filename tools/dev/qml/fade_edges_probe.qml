pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/stocks"
import "modules/stocks/data"
import "modules/weather"
import "modules/weather/data"
import "modules/picker"
import "modules/picker/data"

// =============================================================================
// tools/dev/qml/fade_edges_probe.qml -- a list's edge fade covers everything its clip lets through, at every device-pixel
// phase (tools/dev/fade_edges_probe.sh runs it; read that header first).
//
// The case the user saw (feedback/stocks.md "bottom fadout in list misaligned"): the holdings list's foot fade ended one device
// pixel short of the list's clip, and rows showed through that line. The probe makes the fault visible whatever the rows hold:
// every dressing found in a site (ScrollDressing or CarvedListDressing) gets a MAGENTA sheet over its Flickable's whole content
// (on top of the content), is scrolled so BOTH bands are fully on, and its site stands in a cell at a fractional device-pixel
// phase under the frame's scale. The band's opaque end must then hide the sheet: a pixel past it that is mostly magenta is content
// the clip let through (tools/dev/fade_edges.py judges the picture).
//
// Env:
//   SITE      one site a run (below)
//   REST      1: nothing armed (a before/after of the frames at rest)
//   SCALE     the frame scale every cell stands under (1.25: the user's `scale.global`; the window's own ratio comes on top)
//   PHASES    "fx:fy,..." device-pixel phases of the cells
//   COLS      cells to a row
//   MODE      grab (offscreen: one PNG of the window's content, OUT) | hold (a real window: prints READY and stays for a shot)
// Prints one CELL line per dressing x phase (where the dressing stands, in the window's DEVICE px), then READY (and, in grab
// mode, SAVED <png>).
// =============================================================================
Scope {
    id: root

    readonly property string site: Quickshell.env("SITE") || "synthetic"
    readonly property real frameScale: Number(Quickshell.env("SCALE") || "1.25")
    readonly property var phases: {
        const raw = Quickshell.env("PHASES") || "0:0,0.25:0.25,0.5:0.5,0.75:0.75";
        return raw.split(",").map(p => {
            const a = p.split(":");
            return { fx: Number(a[0]), fy: Number(a[1] === undefined ? a[0] : a[1]) };
        });
    }
    readonly property string mode: Quickshell.env("MODE") || "grab"
    readonly property string outPath: Quickshell.env("OUT") || ""
    readonly property int cols: Number(Quickshell.env("COLS") || "4")
    // REST=1: nothing is armed (no sheet, no scroll): the sites as they stand, for a before/after of the frames the fix must not
    // touch (tools/dev/fade_edges_rest.py). The weather popup holds its floating cards and its sky still there, so two runs agree.
    readonly property bool rest: Quickshell.env("REST") === "1"

    // A cell is the site's size (design px); the sites are listed in `siteComponent`.
    readonly property var cellSizes: ({
            "synthetic": [300, 260], "synthetic-h": [300, 260], "synthetic-lead": [300, 260], "synthetic-cut": [300, 260],
            "carved": [300, 260], "picker": [580, 400], "stocks": [480, 310], "weather": [740, 960]
        })
    readonly property real cellW: (root.cellSizes[root.site] || [300, 260])[0]
    readonly property real cellH: (root.cellSizes[root.site] || [300, 260])[1]
    readonly property int nCells: root.phases.length
    readonly property int nRows: Math.ceil(root.nCells / root.cols)
    readonly property Component siteComponent: root.site === "synthetic" ? synthV
        : root.site === "synthetic-h" ? synthH
        : root.site === "synthetic-lead" ? synthLead
        : root.site === "synthetic-cut" ? synthCut
        : root.site === "carved" ? carvedSite
        : root.site === "picker" ? pickerSite
        : root.site === "stocks" ? stocksSite
        : root.site === "weather" ? weatherSite : null

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: root.cols * root.cellW * root.frameScale + 40
        implicitHeight: root.nRows * root.cellH * root.frameScale + 40
        color: Theme.surface

        // The grab's ground (a grab of a window's content item has no window colour) and the shot's finder: a green square in
        // the window's corner, 8 x 8 px, so a screenshot can find the window's origin.
        Rectangle {
            id: body
            anchors.fill: parent
            color: Theme.surface

            Rectangle {
                x: 0
                y: 0
                width: 8
                height: 8
                color: "#00ff00"
            }

            // The mocks a real site needs (captured fixtures, clocks pinned), inside the window: a visual item made with no
            // window crashes Quickshell.
            StocksMock {
                id: stocksMock
                dryRun: true
                scenario: "market-open"
            }
            WeatherMock {
                id: weatherMock
            }
            // The picker's own service (RAM only, nothing pasted) and style.
            PickerService {
                id: pickerSvc
                live: false
            }
            PickerStyle {
                id: pickerSty
            }

            Repeater {
                id: cellRep
                model: root.nCells
                delegate: Item {
                    id: cell
                    required property int index
                    readonly property var phase: root.phases[cell.index]
                    readonly property int col: cell.index % root.cols
                    readonly property int row: Math.floor(cell.index / root.cols)
                    // Whole DEVICE px plus the phase, in the window's logical px.
                    readonly property real dpr: win.devicePixelRatio > 0 ? win.devicePixelRatio : 1
                    x: (Math.round((20 + cell.col * root.cellW * root.frameScale) * cell.dpr) + cell.phase.fx) / cell.dpr
                    y: (Math.round((20 + cell.row * root.cellH * root.frameScale) * cell.dpr) + cell.phase.fy) / cell.dpr
                    width: root.cellW
                    height: root.cellH
                    scale: root.frameScale
                    transformOrigin: Item.TopLeft

                    // Built once the window exists: a site built before (the window is made after its items here) has no
                    // window to polish in, and a Shape the weather strip polishes by hand then crashes Quickshell.
                    Loader {
                        id: siteLoader
                        active: root._windowUp
                        sourceComponent: root.siteComponent
                    }
                    readonly property Item siteItem: siteLoader.item
                }
            }
        }
    }

    // ---- The sites ---------------------------------------------------------------------------------------------------

    // The plain structure every ScrollDressing host has: a carved box, a clipping Flickable inside it at fractional design px,
    // the dressing over it.
    component SynthSite: Item {
        id: ss
        property int orientation: Qt.Vertical
        property real lead: 0
        property var outline: null
        width: 300
        height: 260
        ShadowBox {
            anchors.fill: parent
            baseRadius: 14
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.listBox
            bevelWidth: 1
            shadowWidth: 3
            shadowFalloff: 1
        }
        Flickable {
            id: fl
            x: 6
            y: 30.4
            width: ss.width - 12.4
            height: 200.3
            clip: true
            interactive: false
            contentWidth: ss.orientation === Qt.Horizontal ? 3000 : fl.width
            contentHeight: ss.orientation === Qt.Horizontal ? fl.height : 3000
        }
        ScrollDressing {
            anchors.fill: fl
            flick: fl
            orientation: ss.orientation
            ground: Theme.listBox
            fadeHeight: 18
            fadeLead: ss.lead
            outline: ss.outline
        }
    }
    Component {
        id: synthV
        SynthSite {}
    }
    Component {
        id: synthH
        SynthSite {
            orientation: Qt.Horizontal
        }
    }
    Component {
        id: synthLead
        SynthSite {
            lead: 6
        }
    }
    // The cut variant (shaders/fade_band.frag): the box's rounded outline, in the dressing's own units.
    Component {
        id: synthCut
        SynthSite {
            outline: ({ x: -6, y: -30.4, w: 300, h: 260, radii: [14, 14, 14, 14] })
        }
    }
    Component {
        id: carvedSite
        Item {
            width: 300
            height: 260
            ShadowBox {
                id: cbox
                x: 10.3
                y: 10.6
                width: 279.4
                height: 230.2
                baseRadius: 14
                surfaceColor: Theme.surface
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                backgroundColor: Theme.listBox
                bevelWidth: 1
                shadowWidth: 3
                shadowFalloff: 1
            }
            Flickable {
                id: cfl
                anchors.fill: cbox
                clip: true
                interactive: false
                contentWidth: cfl.width
                contentHeight: 3000
            }
            CarvedListDressing {
                anchors.fill: cbox
                flick: cfl
                boxColor: Theme.listBox
                surfaceColor: Theme.surface
                bevelColor: Theme.bevel
                radius: 14
                fadeHeight: 18
            }
        }
    }
    // The picker's grid, as the popup builds it (feedback/picker.md): its dressing is the one host that passes an `outline` the clip
    // could be flush with (the box IS the viewport but for the carve's rim), the case the synthetic sites never had.
    Component {
        id: pickerSite
        PickerPopup {
            service: pickerSvc
            // qmllint disable incompatible-type
            style: pickerSty
            // qmllint enable incompatible-type
            width: implicitWidth
            height: implicitHeight
            Component.onCompleted: freshen()
        }
    }
    // The user's case: the holdings list as the popup lays it out (6 rows of 44 under a 30 px header), on the mock's portfolio.
    Component {
        id: stocksSite
        StocksList {
            width: 480
            height: implicitHeight
            service: stocksMock
            rows: 6
        }
    }
    // The weather popup in its normal view: the hourly strip (its clip inset by clipInset) and the daily list, inside the
    // popup's own static layers and floating cards, as the shell draws them.
    Component {
        id: weatherSite
        WeatherPopup {
            service: weatherMock
            eagerCards: true
            viewMode: "normal"
            cardFloat: !root.rest
            backdropRunning: !root.rest
            renderScale: root.frameScale * (win.devicePixelRatio > 0 ? win.devicePixelRatio : 1)
            width: implicitWidth
            height: implicitHeight
        }
    }

    // ---- Find, arm and report every dressing --------------------------------------------------------------------------
    // A dressing is an item with a Flickable `flick` and a `fadeHeight`: ScrollDressing and CarvedListDressing.
    function _dressingsIn(item: var, out: var): void {
        if (!item)
            return;
        if (item.flick !== undefined && item.fadeHeight !== undefined && item.flick && item.flick.width > 1 && item.flick.height > 1
                && item.visible && item.fadeHeight > 0)
            out.push(item);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root._dressingsIn(kids[i], out);
    }
    function _arm(d: var): void {
        const f = d.flick;
        const horiz = d.orientation === Qt.Horizontal;
        // Content long enough for a mid position with both bands fully on (a ramp is a fade-height or two).
        if (horiz)
            f.contentWidth = Math.max(f.contentWidth, f.width + 400);
        else
            f.contentHeight = Math.max(f.contentHeight, f.height + 400);
        sheet.createObject(f.contentItem, { width: Qt.binding(() => f.contentWidth), height: Qt.binding(() => f.contentHeight) });
        if (horiz)
            f.contentX = Math.round((f.contentWidth - f.width) / 2) + 0.37;
        else
            f.contentY = Math.round((f.contentHeight - f.height) / 2) + 0.37;
    }
    Component {
        id: sheet
        Rectangle {
            z: 100000
            color: "#ff00ff"
        }
    }
    property var _found: []

    // The type that hosts a dressing: the nearest ancestor that is not a plain Item.
    function _hostName(d: var): string {
        for (let p = d.parent; p; p = p.parent) {
            const n = String(p).replace(/_QMLTYPE.*|\(.*/, "");
            if (n !== "QQuickItem" && n !== "QQuickFlickable")
                return n;
        }
        return "?";
    }
    function _report(): void {
        for (let i = 0; i < root._found.length; i++) {
            const e = root._found[i], d = e.d, c = e.cell, dpr = c.dpr;
            const a = d.mapToItem(body, 0, 0), b = d.mapToItem(body, d.width, d.height);
            const horiz = d.orientation === Qt.Horizontal;
            console.log("CELL " + JSON.stringify({
                i: c.index, k: e.k, site: root.site + (e.n > 1 ? "#" + e.k + ":" + root._hostName(d) : ""),
                fx: c.phase.fx, fy: c.phase.fy, horiz: horiz, dpr: dpr, scale: root.frameScale,
                x0: a.x * dpr, y0: a.y * dpr, x1: b.x * dpr, y1: b.y * dpr,
                head: d._headF !== undefined ? d._headF : (d.moreAbove ? 1 : 0),
                foot: d._footF !== undefined ? d._footF : (d.moreBelow ? 1 : 0),
                ground: String(d.ground !== undefined ? d.ground : d.boxColor)
            }));
        }
    }

    property bool _windowUp: false
    // Smoked bare (no runner, so no OUT in grab mode) it drives nothing: a 0 ms quit instead of a grab to "".
    readonly property bool _bare: root.mode === "grab" && root.outPath === ""
    Timer {
        interval: 0
        running: true
        onTriggered: {
            if (root._bare) {
                console.log("FADE_EDGES bare run (no OUT): nothing to judge");
                Qt.quit();
                return;
            }
            root._windowUp = true;
        }
    }
    Timer {
        id: armTimer
        // A real site builds its cards and loads its data first (the weather popup's eager cards, the mocks' fixtures).
        interval: root.site === "weather" ? 4000 : 1500
        running: !root._bare
        onTriggered: {
            const all = [];
            for (let i = 0; i < cellRep.count; i++) {
                const c = cellRep.itemAt(i);
                const ds = [];
                root._dressingsIn(c ? c.siteItem : null, ds);
                if (!ds.length)
                    console.log("CELL " + JSON.stringify({ i: i, site: root.site, error: "no dressing found" }));
                for (let k = 0; k < ds.length; k++) {
                    if (!root.rest)
                        root._arm(ds[k]);
                    all.push({ d: ds[k], cell: c, k: k, n: ds.length });
                }
            }
            root._found = all;
            settleTimer.start();
        }
    }
    Timer {
        id: settleTimer
        // The CarvedListDressing's own 160 ms fades, a layer's re-render, a frame or two.
        interval: 1200
        onTriggered: {
            root._report();
            console.log("READY");
            if (root.mode === "grab")
                body.grabToImage(r => {
                    r.saveToFile(root.outPath);
                    console.log("SAVED " + root.outPath);
                    quitTimer.start();
                });
        }
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
}
