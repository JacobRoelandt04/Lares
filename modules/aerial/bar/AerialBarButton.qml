pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/glyphs"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "NetTraffic.js" as Traffic
import "BtBattery.js" as Battery
import "AerialPill.js" as PillFacts
import "../../clock"
import "parts/NetPose.js" as Pose

// =============================================================================
// AerialBarButton.qml -- aerial's bar pill: the networking and bluetooth glyphs in ONE pill, which is ONE button (any click
// opens the one popup: no halves, no sections).
//
// Two glyph halves under a single hit handler -- the shape `modules/bar/audio/AudioBarButton.qml` established for
// output-and-input. The handler still tells which half the pointer is on, but only for the FLOURISH (each half plays its own);
// the hover ink and the click are the pill's.
//
// WHAT IT READS: `service` (an AerialService or its mock: wifi, wired, hotspot, bt, proton, health, airplane, rates), folded by
// AerialPill.js into one record. THE STATES OF THE NET HALF, besides the Wi-Fi fan's level, the wire, the plane: a hotspot that is
// up shows the broadcasting glyph in place of the fan; a tunnel that is up puts a small padlock on the glyph (a badge: its own item,
// so the fan's flourish moves the fan only); a Public network with no tunnel puts an open padlock there, in the warn colour; a pad
// that failed the health tests takes the glyph to the warn colour (a portal, a slow DNS) or the error colour (a failed pad).
// The states with no outline of their own in parts/NetParts.js (the hotspot's glyph) play no flourish.
//
// ON IS A COLOUR, NOT A SHAPE. A radio that is on wears its half's ON hue (BarHues `wifiOn` / `btOn`,
// neighbours on the hue circle); one that is off -- the radio switched off, airplane mode, no adapter,
// a wired socket with nothing in it -- is the same glyph family in the muted ink: no slashed glyph.
// The shapes that carry information stay (the Wi-Fi bars, the wired socket, Bluetooth's connected
// dots, the plane in airplane mode, the "!" of a link that reaches nothing), and a link that is up
// but DEGRADED (a captive portal, limited) is the one state in the warn colour.
//
// ONLY THE POINTER IS ANNOUNCED, AND ON THE CARVED PILL, as silicon's button does (SiliconBarFace): hovering eases the pill's
// own fill one shade deeper (`hoverF`, one fraction on the bar's one hover clock; fill and edge are silicon's tokens and
// depths). The glyphs take NO hover colour and NO colour for an open popup (`popupOpen` is the owner's fact, nothing is
// drawn for it): a glyph keeps its state hue, which is the information. A glyph is NEVER faint.
//
// NO COLOUR IS ANIMATED HERE, as in AudioBarButton, which this follows in every
// other respect. A `Behavior on color` makes a button arrive 120 ms after the card
// it sits on, because a Behavior cannot tell a hover from the theme moving underneath
// it. Hover and active are eased FRACTIONS and the colours are mixed with
// Mix.js, so at rest the value IS a theme token and a switch reaches it with
// no clock in between.
//
// THE FLOURISHES. Each half has one, of the signal family (parts/NetPose.js): the Wi-Fi fan pings (a kick from its tip and
// one arc thrown off its rim; the fill it shows never changes), the wire passes data (bulges that run down it, box to box),
// the plane makes a cartoon take-off run (bunched up, then stretched, wind behind it), Bluetooth's rune -- one line -- is
// pulled round so it empties and fills again. It plays when the pointer comes onto ITS half and moves (GlyphFlourish's rule,
// fed from the one hit area) and at random with the OLED care (group `aerial`, glyphs `wifi` and `bluetooth`); a network
// half that is off makes the start and nothing comes out, the rune plays the same on or off (its ink says which).
//
// THE TRAFFIC FIGURES. While the
// link carries a transfer, the pill WIDENS into the margins either side of it and the down / up
// rates stand between the two icons (NetTraffic.js: when, and what a figure is), each figure
// with its arrow right of it. The pair's own size never changes -- `implicitWidth` is the
// resting pill's -- so the bar's layout, the right island's length and the neighbours do not
// move: the pill grows into the gap, and the shell's ink gap (ShellLayout.TRAFFIC_REACH + 8 clear) is what
// pays for it. HOW FAR it grows is what the figures need: `reach` px a side for three digits, and
// half a digit's width less for each digit fewer, so a figure of one digit does not carry the
// room of two more. A pill that grows is one eased extent (260 ms
// OutCubic) and the figures' block follows it, so the arrows stay glued to the pill's middle;
// the figures fade in with it (160 ms). Four figures cannot happen (NetTraffic caps at 999).
//
// THE BATTERY STRIPE. Between the two icons stands the calendar's gauge (clock/ProgressStripe: an event row's stripe
// erased from the top as its time runs out; here the connected device's charge), 2 px wide (even, so it stands on whole
// pixels at the pill's middle) and 14 tall. BtBattery.js holds the rules: the LOWEST charge of the connected devices that
// report one, the lower bud of earbuds (never the case), nothing when none reports. The stripe is the Bluetooth half's own
// "on" hue, warn at or below 20 %, error at or below 10 %, the ok token while UPower says it charges; the colour is a mix on
// eased fractions (no Behavior on a colour). It is not a glyph and takes no room: the icons never move. It APPEARS by growing
// up from its foot and DISAPPEARS by shrinking down to it (its drawn length is `batteryPresence` x 14, ONE eased fraction; the
// fill inside is a share of the drawn length, so it goes with it). It yields to the traffic figures, which stand in the same
// gap while a transfer runs: the stripe shrinks first and fast (`batteryYieldMs`), the figures' fade starts once it is
// `figuresAfterLen` short (their two inks never overlap above 0.3 presence), and after the traffic the stripe waits
// `regrowDelayMs` with none before it grows back (it would otherwise blink with every burst). Horizontal bars only (the side
// bars' pill is a column). A percentage does not fit: the ink gap between the icons is ~11 px.
//
// The glyphs are Nerd Font codepoints written as escapes, every one of them
// checked against the installed font BY NAME (a codepoint that is merely
// present is not the glyph you meant -- md-image_plus sits where a mouse might be
// assumed).
// =============================================================================
Item {
    id: root

    // ---- what it shows -----------------------------------------------------
    property var service: null               // AerialService | AerialMock
    property bool popupOpen: false           // the popup is up and ours (the owner's fact; nothing is drawn for it, as silicon's `active`)
    // THE FACTS, read at one serial (the service bumps `serial` LAST): one record (AerialPill.js).
    readonly property var _facts: {
        const s = root.service;
        if (!s)
            return null;
        void s.serial;
        return { wifi: s.wifi, wired: s.wired, hotspot: s.hotspot, bt: s.bt, proton: s.proton, health: s.health, airplane: s.airplane, rates: s.rates, helper: s.helper };
    }
    readonly property var pill: PillFacts.of(root._facts)
    // Airplane mode is in effect: the plane takes the Wi-Fi half's place (the service's memory, so it holds with no popup open).
    readonly property bool airplane: root.pill.airplane

    // ---- the traffic figures -----------------------------------------------
    // The service's `rates`: { iface, rxBps, txBps, atMs }, replaced whole at every reading (`atMs` moves each time). null, or atMs 0, is
    // no reading. Horizontal bars only: the side bars' pill is a
    // column with no room beside its icons.
    readonly property var traffic: root.service ? root.service.rates : null
    property bool trafficEnabled: true
    // px the pill may grow into each side's margin at three figures, in the shell's face (Audiowide: at 8 the "1"
    // stands on the wifi glyph); ShellLayout.TRAFFIC_REACH is the same number and leaves 8 px of the ink gap clear.
    property real reach: 14
    property string fontFamily: "Inter"
    property var trafficConfig: ({})          // NetTraffic.step's `cfg`: thresholds, hold, cap

    property var _tstate: Traffic.fresh()
    readonly property bool trafficShown: root._tstate.shown && root._horizontal && root.trafficEnabled
    onTrafficChanged: {
        const t = root.traffic;
        const st = !t || !t.atMs ? Traffic.fresh()
            : Traffic.step(root._tstate, t.rxBps, t.txBps, root.trafficConfig);
        root._tstate = st;
        // An arrow bobs on every reading while its figure is not 0 (NetTraffic.js `rxBob`):
        // decided once per reading, so at most one 260 ms bob a direction a beat, and none while the figures are not up.
        // Both on one reading: each bobs 1 px, so the tips never touch (NetTrafficFigures).
        const both = root.trafficShown && st.rxBob && st.txBob;
        if (root.trafficShown && st.rxBob)
            figures.bobRx(both);
        if (root.trafficShown && st.txBob)
            figures.bobTx(both);
    }
    // The arrows' bob fractions (0 at rest, 1 at the far end), the pixels they stand off their rest place and the clear
    // rows between the tips: what a probe counts and gates bobs by.
    readonly property alias rxKick: figures.rxKick
    readonly property alias txKick: figures.txKick
    readonly property alias rxShift: figures.rxShift
    readonly property alias txShift: figures.txShift
    readonly property alias arrowClearance: figures.arrowClearance
    // One digit's cell at the figures' face (what the pill's growth per digit is made of; a probe reads it).
    readonly property real figureDigitW: figures.digitW
    // Px the pill is to have grown past each end of the slot: `reach` at three digits, a half
    // digit less for each fewer, in whole pixels (the pill's edges stay on the pixel grid).
    readonly property real _overhangTarget: root.trafficShown
        ? Math.max(0, Math.round(root.reach - (3 - root._tstate.digits) * root.figureDigitW / 2)) : 0
    // The ONE clock of the growth: the pill's extent, and with it the figures' block.
    property real overhang: root._overhangTarget
    Behavior on overhang { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    // The figures' presence: they wait until the battery stripe has shrunk out of their way.
    property real _present: root.trafficShown && root._batDrawn <= root.figuresAfterLen ? 1 : 0
    Behavior on _present { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    // The service folds UPower's parts into each device's `battery` (AerialModel.btBattery).
    readonly property var batterySummary: Battery.summaryOfDevs(root._facts && root._facts.bt ? root._facts.bt.devices : [])
    // The share the stripe holds while it fades out (a device that went takes its figure with it, not a jump to empty).
    property real _batFill: 1
    readonly property real _batFillNow: root.batterySummary.fraction
    on_BatFillNowChanged: if (root.batterySummary.shown) root._batFill = root._batFillNow
    Component.onCompleted: {
        if (root.batterySummary.shown)
            root._batFill = root._batFillNow;
        // born with the stripe in force: no growth at the start
        batteryAnim.stop();
        root.batteryPresence = root._batShown ? 1 : 0;
    }
    // THE STRIPE'S MOTION. One eased fraction, `batteryPresence` (0 absent .. 1 full length), driven by `batteryAnim`: it grows from
    // the foot (OutCubic) and shrinks to it (InCubic). No Behavior: the duration depends on WHY it shrinks, which a Behavior reads a turn late.
    property real batteryWidth: 2              // even: whole pixels at the pill's middle
    property real batteryLength: 14            // the full drawn length
    property int batteryGrowMs: 300            // appearing: the stripe lengthens from its foot
    property int batteryShrinkMs: 220          // a device gone: it shortens to its foot
    property int batteryYieldMs: 140           // traffic takes the gap: fast, the figures are waiting for the room
    property int regrowDelayMs: 1500           // no traffic for this long before the stripe grows back (a burst does not blink it)
    property real figuresAfterLen: 3           // the figures start fading in once the stripe is this short (px): the last 3 px of an InCubic
                                               // yield take ~11 ms, under which the figures are below 0.3 presence
    property bool _batHold: false              // traffic is up, or has been within regrowDelayMs
    onTrafficShownChanged: {
        if (root.trafficShown) {
            root._batHold = true;
            regrowTimer.stop();
        } else if (root._batHold) {
            regrowTimer.restart();
        }
    }
    Timer {
        id: regrowTimer
        interval: root.regrowDelayMs
        onTriggered: root._batHold = false
    }
    readonly property bool _batShown: root.batterySummary.shown && root._horizontal && !root.trafficShown && !root._batHold
    property real batteryPresence: 0
    // the length on screen, px
    readonly property real _batDrawn: root.batteryLength * root.batteryPresence
    on_BatShownChanged: {
        batteryAnim.stop();
        batteryAnim.to = root._batShown ? 1 : 0;
        batteryAnim.duration = root._batShown ? root.batteryGrowMs : root.trafficShown ? root.batteryYieldMs : root.batteryShrinkMs;
        batteryAnim.easing.type = root._batShown ? Easing.OutCubic : Easing.InCubic;
        batteryAnim.start();
    }
    NumberAnimation {
        id: batteryAnim
        target: root
        property: "batteryPresence"
    }
    readonly property bool _batLowNow: root.batterySummary.shown && root.batterySummary.level !== "ok"
    readonly property bool _batCritNow: root.batterySummary.shown && root.batterySummary.level === "crit"
    readonly property bool _batChargingNow: root.batterySummary.shown && root.batterySummary.charging
    property real _batLowF: root._batLowNow && !root._batChargingNow ? 1 : 0
    property real _batCritF: root._batCritNow && !root._batChargingNow ? 1 : 0
    property real _batChgF: root._batChargingNow ? 1 : 0
    Behavior on _batLowF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _batCritF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _batChgF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    readonly property color batteryColor: Mix.c(Mix.c3(BarHues.btOn, Theme.warn, root._batLowF, Theme.error, root._batCritF), Theme.ok, root._batChgF)

    property string orientation: "horizontal"
    readonly property bool _horizontal: root.orientation === "horizontal"

    // ---- geometry ----------------------------------------------------------
    property real halfLength: 26
    property real thickness: 26
    property int iconPixelSize: 15
    // the padlock badge's size and its offset from the half's middle (the fan's lower right is empty: the fan is a wedge)
    property int badgePixelSize: 8
    property real badgeDx: 2
    property real badgeDy: -1

    implicitWidth: root._horizontal ? 2 * root.halfLength : root.thickness
    implicitHeight: root._horizontal ? root.thickness : 2 * root.halfLength

    // any click on the pill: the one popup
    signal clicked()

    // ---- the facts each half draws ----------------------------------------
    // the worst tested pad: a portal / slow check (warn) or a failed one (error); either draws the "!" fan
    readonly property bool _degraded: root.pill.fault !== ""

    // md-wifi_strength_1/2/3/4 are NOT consecutive: each level is followed by
    // its _alert and _lock variants, so the four sit three apart.
    readonly property var _wifiGlyphs: ["\u{F092F}", "\u{F091F}", "\u{F0922}", "\u{F0925}", "\u{F0928}"]
    readonly property var _wifiAlert: ["\u{F092B}", "\u{F0920}", "\u{F0923}", "\u{F0926}", "\u{F0929}"]

    // The wired socket is the whole story: a link over it, or no Wi-Fi device at all and a wired one.
    readonly property bool _wiredShown: root.pill.wiredShown
    // The net half is ON: a link over the wire, the Wi-Fi radio up (connected or looking) or the hotspot. Off is the muted ink.
    readonly property bool netOn: root.pill.netOn
    readonly property int _bars: root.pill.bars
    readonly property string netGlyph: {
        if (root.airplane)
            return "\uf072";                                  // fa-plane
        if (root.pill.hotspotOn)
            return "\u{F0003}";                               // md-access_point: broadcasting, in place of the fan
        if (root._wiredShown)
            return "\u{F0318}";                               // md-lan_connect, on or not (the colour says which)
        if (!root.netOn)
            return "\u{F092F}";                               // md-wifi_strength_outline: the Wi-Fi shape, no bars
        const lvl = Math.max(0, Math.min(4, root._bars));
        return root._degraded ? root._wifiAlert[lvl] : root._wifiGlyphs[lvl];
    }
    // The badge on the net glyph's lower right: a tunnel is up (md-lock) or the network is Public with none (md-lock_open, warn).
    readonly property string netBadge: root.pill.vpnUp ? "\u{F033E}" : root.pill.publicOpen ? "\u{F033F}" : ""

    readonly property bool _btConnected: root.pill.btConnected
    // The Bluetooth half is ON: an adapter, powered and not blocked.
    readonly property bool btOn: root.pill.btOn
    // md-bluetooth, or md-bluetooth_connect while a device is connected; off is the plain glyph in the muted ink
    readonly property string btGlyph: root.btOn && root._btConnected ? "\u{F00B1}" : "\u{F00AF}"

    // ---- the states each half eases through ---------------------------
    // The pointer: one fraction on the bar's one hover clock; the pill's carved fill mixes by it (the pill is one button).
    property real hoverF: root._hoverSide !== "" ? 1 : 0
    Behavior on hoverF { GlyphHoverEase {} }
    // silicon's depths (SiliconBarFace): hover is 0.4 of a step from the fill toward `border`, the edge goes to `shadowDeep`
    readonly property real hoverDepth: 0.4
    readonly property color pillFill: Mix.c(Theme.listBox, Theme.border, root.hoverDepth * root.hoverF)
    readonly property color pillEdge: Mix.c(Theme.border, Theme.shadowDeep, root.hoverF)

    property string _hoverSide: ""

    // On, degraded (warn: connected, and connected to nothing useful; a pad that failed is the error colour): the shell's
    // presence fade (160 ms).
    property real _onNet: root.netOn ? 1 : 0
    property real _onBt: root.btOn ? 1 : 0
    property real _warnNet: (root.netOn || root.pill.helperFailed) && root.pill.fault === "warn" ? 1 : 0
    property real _errNet: root.netOn && root.pill.fault === "error" ? 1 : 0
    // the open padlock's mark is the warn colour whatever the glyph's ink is
    property real _openF: root.pill.publicOpen ? 1 : 0
    Behavior on _errNet { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _onNet { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _onBt { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _warnNet { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    readonly property color _netRest: Mix.c(Mix.c3(Theme.textMuted, BarHues.wifiOn, root._onNet, Theme.netLampWarn, root._warnNet), Theme.error, root._errNet)
    readonly property color _btRest: Mix.c(Theme.textMuted, BarHues.btOn, root._onBt)

    // ---- chrome: one pill --------------------------------------------------
    ShadowBox {
        id: chrome
        x: -root.overhang
        y: 0
        width: root.width + 2 * root.overhang
        height: root.height
        baseRadius: Math.min(width, height) * 0.5
        bevelWidth: 0                       // no lit rim outside the edge, as silicon's pill
        shadowWidth: 2.5
        surfaceColor: "transparent"
        backgroundColor: root.pillFill
        bevelColor: Theme.bevel
        shadowColor: root.pillEdge
    }

    component Half: Item {
        id: half
        property string glyph: ""
        property color restColor: Theme.textMuted
        // a small mark on the glyph's lower right (the net half's padlocks): its own item, so a flourish moves the glyph's ink only
        property string badge: ""
        property color badgeColor: restColor

        // The flourish (the header): its clock, and the half's glyph posed on it. `live` is the half being on.
        property bool live: true
        property string flourishName: ""
        readonly property alias flourish: ping
        readonly property alias glyphItem: posed
        GlyphFlourish {
            id: ping
            group: "aerial"
            glyph: half.flourishName
            decorative: true
            host: half
            armed: root.flourishEnabled && Pose.has(half.glyph)
            ms: Pose.life(half.glyph, half.live)
            overlap: "ignore"
        }
        // the glyph posed on the clock: its parts, and each part's share of the ink
        readonly property var pose: ping.playing
            ? Pose.pose(half.glyph, ping.t, ping.ms, half.live, null, posed.pixelSize, posed.origin.x, posed.origin.y) : null
        // The plain Text at rest (PosedGlyph).
        PosedGlyph {
            id: posed
            anchors.centerIn: parent
            text: half.glyph
            pixelSize: root.iconPixelSize
            posing: ping.playing
            parts: half.pose ? half.pose.parts : []
            shades: half.pose ? half.pose.shades : []
            // the ink is the state's hue at rest, under the pointer and with the popup open alike
            color: half.restColor
        }
        Text {
            visible: half.badge !== ""
            text: half.badge
            font.family: "Symbols Nerd Font"
            font.pixelSize: root.badgePixelSize
            font.bold: false
            x: Math.round(half.width / 2 + root.badgeDx)
            y: Math.round(half.height / 2 + root.badgeDy)
            color: half.badgeColor
        }
    }

    Half {
        id: netHalf
        x: -root.overhang
        y: 0
        width: root._horizontal ? root.width / 2 : root.width
        height: root._horizontal ? root.height : root.height / 2
        glyph: root.netGlyph
        restColor: root._netRest
        // the plane IS airplane mode: it flies whole
        live: root.netOn || root.airplane
        flourishName: "wifi"
        badge: root.netBadge
        badgeColor: Mix.c(root._netRest, Theme.netLampWarn, root._openF)
    }
    Half {
        id: btHalf
        x: root._horizontal ? root.width / 2 + root.overhang : 0
        y: root._horizontal ? 0 : root.height / 2
        width: netHalf.width
        height: netHalf.height
        glyph: root.btGlyph
        restColor: root._btRest
        live: root.btOn
        flourishName: "bluetooth"
    }

    // ---- the flourishes (the header) ----
    property bool flourishEnabled: true
    readonly property GlyphFlourish netFlourish: netHalf.flourish
    readonly property GlyphFlourish btFlourish: btHalf.flourish
    // the glyph items (a probe reads their parts)
    readonly property PosedGlyph netGlyphItem: netHalf.glyphItem
    readonly property PosedGlyph btGlyphItem: btHalf.glyphItem
    // The pointer's rule per half, from the one area: where the pointer is in the WINDOW, and which half it is on.
    function _pointer(side: string, x: real, y: real): void {
        const p = hit.mapToItem(null, x, y);
        netHalf.flourish.pointerAt(side === "net", p.x, p.y);
        btHalf.flourish.pointerAt(side === "bt", p.x, p.y);
    }

    ProgressStripe {
        id: battery
        objectName: "btBattery"
        visible: root.batteryPresence > 0.001
        width: root.batteryWidth
        // the foot stays where the full stripe's is; the length is what moves
        height: root._batDrawn
        x: Math.round((root.width - battery.width) / 2)
        y: Math.round((root.height - root.batteryLength) / 2) + root.batteryLength - battery.height
        color: root.batteryColor
        ground: root.pillFill
        fill: root._batFill
        fromBottom: true
    }

    NetTrafficFigures {
        id: figures
        visible: root._present > 0.001
        opacity: root._present
        // The block is as wide as the pill has grown beyond what three digits need.
        blockWidth: Math.max(figures.arrowW + figures.arrowGap + figures.digitW, figures.fullWidth - 2 * (root.reach - root.overhang))
        x: Math.round((root.width - figures.blockWidth) / 2)
        y: Math.round((root.height - figures.implicitHeight) / 2)
        rx: root._tstate.rx
        tx: root._tstate.tx
        rxActive: root._tstate.rxActive
        txActive: root._tstate.txActive
        fontFamily: root.fontFamily
    }

    // One handler over both halves, so neither can steal the other's hover and
    // the pill reads as one object. Which half is arithmetic, not hit-testing (it only picks the flourish).
    MouseArea {
        id: hit
        x: -root.overhang
        y: 0
        width: root.width + 2 * root.overhang
        height: root.height
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor

        function _side(mx, my) {
            return (root._horizontal ? mx < width / 2 : my < height / 2)
                ? "net" : "bt";
        }
        onPositionChanged: mouse => {
            root._hoverSide = containsMouse ? hit._side(mouse.x, mouse.y) : "";
            root._pointer(root._hoverSide, mouse.x, mouse.y);
        }
        onContainsMouseChanged: {
            if (!containsMouse)
                root._hoverSide = "";
            // an entry with no motion yet: the half under the pointer is where it came in
            root._pointer(containsMouse ? hit._side(hit.mouseX, hit.mouseY) : "", hit.mouseX, hit.mouseY);
        }
        onClicked: root.clicked()
    }
}
