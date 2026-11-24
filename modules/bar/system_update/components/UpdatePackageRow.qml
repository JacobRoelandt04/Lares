pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/components/Mix.js" as Mix
import "../../../common/components"
import "../../../common/theme"

// =============================================================================
// UpdatePackageRow.qml
//
// One available-update row, styled after the calendar's AppointmentRow:
// borderless, with a coloured stripe on the left and the text block to its
// right. The enclosing list panel supplies the ShadowBox; rows themselves draw
// no background except a faint hover wash.
//
// Layout
//   [stripe] [icon]  package-name
//                    new-version                            (collapsed)
//                    new-version ─ current-version    (expanded; icon = link)
//
// The icon comes from a PackageIcons registry supplied by the host, sits
// between the colour stripe and the text, and grows linearly with the row as
// it expands — it is given whatever extra height the expansion frees up.
//
// The version block is a FromToPair: collapsed it shows only the version you
// are moving TO; expanding swings the current version out and rotates the
// connector into place, growing the row to make room.
//
// Colour semantics (per category, not per row):
//   favourite      full-strength category colour
//   not favourite  same hue drained almost to grey — "a grey with a note of
//                  colour in it" — so favourites read as the only saturated
//                  marks in the list and the category is still identifiable.
//
// Interaction
//   left click   toggle the version reveal
//   right click  emit toggleFavoriteRequested() (the host owns the animation)
//   icon click   (expanded only) emit openUrlRequested(); the host resolves
//                and opens the package's upstream URL -- see PackageUrlOpener
//
// A GROUP IS THIS SAME ROW (`isGroup`), in a style similar to the grouped notifications, adapted to
// the list item. Packages that share a prefix are ONE row in the
// list's own style -- stripe, icon, the prefix as the name -- with "+N more" where the version
// stands, and a chevron at the right end (the notification bundle's cue); a click opens it in
// place (`activated()`; the packages step in under it) instead of revealing a version. The
// stripe is the favourite mark of a package row, in full when every package of the group is.
// =============================================================================
Item {
    id: row
    objectName: row.isGroup ? "updateGroupRow" : "updatePackageRow"

    // ---- A group's row ----
    property bool isGroup: false
    // Whether the group is open (the host keeps it); the chevron turns on it.
    property bool groupOpen: false
    // What stands where a package's version does: "+12 more", "12 packages" once open.
    property string groupLine: ""
    signal activated()
    property real chevronSize: 13

    // ---- Data ----
    property var entry: null                 // {name, oldVer, newVer, category, isFavorite, …}
    property color categoryColor: "#4480F4"

    // ---- Styling ----
    property color textColor:  "#5D5D5F"
    property color mutedColor: "#8A8A8C"
    property color faintColor: "#B8BBC2"
    property string fontFamily: "Inter"
    property int nameSize: 13
    property int versionSize: 11
    // Uniform scale for the row. Every size below multiplies by it, and the
    // section measures the resulting height rather than assuming one, so the
    // stagger / viewport maths stays correct at any scale.
    property real listScale: 1.0
    readonly property real _s: Math.max(0.2, listScale)

    property real stripeWidth: 3
    // Left inset of the stripe; headers keep their own padding. The two have to agree, or
    // the rows' colour bars sit on different x and the column reads crooked.
    property real sidePadding: 2
    property real padRight: 6
    property real vPad: 4

    // ---- Run state ----
    //
    // Empty while idle, so a row outside a run draws exactly as before. The
    // host resolves glyph and colour, reusing the same two functions the rest
    // of the popup uses rather than keeping a second copy of the vocabulary.
    readonly property string runState: entry && entry.runState ? entry.runState : ""
    readonly property int    dlPct:    entry && entry.dlPct ? entry.dlPct : 0
    readonly property string dlRate:   entry && entry.dlRate ? entry.dlRate : ""
    readonly property string dlEta:    entry && entry.dlEta ? entry.dlEta : ""
    // Set by the host only on the one package a single-focus step is working
    // on — the installing package, or the AUR package being built and its
    // current build step. Download has twenty at once and no single focus, so
    // it uses the per-row rate below instead.
    property string activeDetail: ""
    // While a step is retiring finished rows, a finished row says so on its
    // second line ("Downloaded", "Installed") instead of dropping back to the
    // version it is about to leave with. The version is useless there, and
    // the text under the name must not snap in the row's last frames.
    property bool showDoneLabel: false
    readonly property real dlBytes: entry && entry.dlBytes ? entry.dlBytes : 0
    readonly property bool  isAur: !!(entry && entry.isAur)

    // What this row says about itself while it is the active one, as plain
    // text: the done label, or the build step during an AUR build. Nothing
    // at rest -- and nothing during a download, whose figures are laid out
    // by the DownloadStats block below instead (`_showStats`).
    readonly property string _liveDetail: {
        if (row.showDoneLabel && (row._stepStatus === "done" || row._stepStatus === "failed")) {
            if (row._stepStatus === "failed") return "Failed";
            switch (row.runState) {
                case "downloaded": return "Downloaded";
                case "installed":  return "Installed";
                case "built":      return "Built";
                case "removed":    return "Removed";
                default:           return "Done";
            }
        }
        if (row._stepStatus !== "active") return "";
        return row.activeDetail;
    }
    // "12.3 / 148.2 MiB  ·  2.4 MiB/s  ·  00:12" while this row is the one
    // downloading: the size is what the rate and the time are about, so it
    // comes first. Each figure sits in its own fixed slot so a tick that
    // changes a digit count moves nothing beside it.
    readonly property bool _showStats:
        row._liveDetail.length === 0
        && ((row._stepStatus === "active"
             && (row.dlBytes > 0 || row.dlRate.length > 0 || row.dlEta.length > 0))
            || (row.sizeWhenPending && row._stepStatus === "pending" && row.dlBytes > 0))
    // In a step that moves bytes, a row still waiting its turn shows its
    // size alone ("11.5 MiB") where the live figures will go -- the same
    // rule the headers follow before the first byte moves.
    property bool sizeWhenPending: false
    // Smaller figures for a narrow list (the verbose view's side panel), so
    // the whole line fits without the ETA being cut off.
    property bool compactStats: false
    property int  statsSizeCompact: 10
    // Which edge of the row the figures are pinned to. Left keeps them under
    // the name; right lines the rate and ETA up in columns across rows, at
    // the cost of a ragged start.
    property int  statsAlignment: Qt.AlignLeft
    // function(rawState) -> "pending" | "active" | "done" | "failed"
    property var stepStatusFor: null

    // The mark describes the row's standing in the CURRENT step, not its raw
    // state: a package that has finished downloading is done while the run is
    // downloading, and pending again once it starts installing.
    readonly property string _stepStatus:
        stepStatusFor ? stepStatusFor(runState, row.isAur) : ""

    // A run is happening for this row at all (queued counts — it is a
    // transaction member waiting its turn).
    readonly property bool inRun: runState.length > 0

    // How far this row is through the CURRENT step, 0..1. Only the download
    // step reports sub-package progress; install and build are all-or-nothing
    // because that is all pacman and makepkg report.
    readonly property real stripeProgress:
        row._stepStatus === "done" || row._stepStatus === "failed" ? 1
      : row._stepStatus === "active" ? Math.max(0, Math.min(1, row.dlPct / 100))
      : 0



    // ---- Icon ----
    // Resolved by the host from a PackageIcons registry; empty hides the slot.
    property string iconGlyph: ""
    property string iconFontFamily: "Symbols Nerd Font"
    property real iconBaseSize: 15
    // How much bigger the glyph gets at full expansion. Linear in the expand
    // fraction, matching the row's own growth rather than easing separately.
    property real iconExpandGrowth: 13
    property real iconGap: 9
    // Deliberately colourless: sits between the muted and faint text tones so
    // it reads as texture rather than competing with the name or the stripe.
    property real iconTone: 0.5

    // ---- yay's menu number ----
    //
    // Shown only while yay is parked at one of its numbered prompts, because
    // that is the only time the number means anything: it is what you type to
    // exclude a package, view its diff, or force a clean build. Outside those
    // prompts it is noise, so it takes no space at all.
    //
    // Sized and grown exactly like the icon, so an expanding row scales both
    // together rather than leaving the number pinned at its resting size.
    property bool showNumber: false
    property int packageNumber: 0
    property real numberBaseSize: 12
    property real numberExpandGrowth: 10
    property real numberGap: 8
    property color numberColor: mutedColor

    readonly property bool _hasNumber: showNumber && packageNumber > 0
    // Numbers arrive with a prompt, on rows that are already showing. The
    // slot opens over a short animation and the digit fades in with it, so
    // the name is nudged aside rather than snapped.
    property real _numberReveal: _hasNumber ? 1 : 0
    Behavior on _numberReveal {
        NumberAnimation { duration: row.animDuration; easing.type: Easing.OutCubic }
    }
    readonly property real _numberSize:
        (numberBaseSize + row._expandFraction * numberExpandGrowth) * row._s
    readonly property real _numberSlot: _numberReveal > 0
        ? (Math.max(numberBaseSize * _s, _numberSize) * 1.4 + numberGap * _s) * _numberReveal : 0

    readonly property bool _hasIcon: iconGlyph.length > 0
    readonly property real _iconSize: (iconBaseSize + row._expandFraction * iconExpandGrowth) * row._s
    readonly property real _iconSlot: _hasIcon ? Math.max(iconBaseSize * _s, _iconSize) + iconGap * _s : 0
    readonly property real padLeft:
        (sidePadding + stripeWidth + 8) * _s + _iconSlot + _numberSlot

    property int animDuration: 240
    property int animEasing: Easing.InOutCubic

    // Drain applied to the stripe of a non-favourite row.
    //
    // `mutedSaturation` is what is left of the category's saturation. Its
    // LIGHTNESS is not an absolute: it travels a fixed fraction of
    // the way from the ground the row lies on toward mid-grey. One absolute
    // value cannot serve both themes -- 0.72 is a drained stripe on a light
    // list and a bright one on a dark list, brighter than the category colour
    // that is supposed to LIGHT IT UP as progress fills it, so the fill would have
    // nothing left to say. Relative to the ground it drains in both, and
    // because the ground is a theme token it crossfades with everything else.
    //
    // 0.4732 reproduces a lightness of 0.72 exactly on the light list box.
    property color mutedGroundColor: "#E5E8EF"
    property real mutedSaturation: 0.22
    property real mutedLightnessMix: 0.4732
    property color errorColor: Theme.error   // a failed row in the theme's own red (no host passes one)
    // How long the icon takes to take on the category colour once its package
    // is finished. Not proportional to progress — the stripe already says
    // that; this is a completion mark, so it simply happens.
    property int completeFadeMs: 420

    // ---- State ----
    property bool expanded: false
    // Host-driven override used by the favourite-flight animation: while a row
    // is the one in flight the host hides the real row and shows a clone.
    property bool contentVisible: true

    signal toggleFavoriteRequested()

    // ---- Upstream link ----
    //
    // The package's ICON is the link, and only while the row is expanded.
    // Expanding is "tell me more about this version", and the changelog is
    // the rest of that answer; a separate glyph for it would be one more mark
    // on every open row. Nothing announces the link but the pointer: the
    // icon takes the category's colour under it and the cursor changes.
    // Collapsed, the icon is just an icon -- no hover, no click.
    //
    // The row opens nothing itself. Clicking the icon emits
    // openUrlRequested() -- and only that: it never toggles the row. The
    // host resolves the URL (see PackageUrlOpener) and, while it does, sets
    // `linkBusy` on this one row, so the icon breathes and ignores clicks.
    signal openUrlRequested()
    property bool linkBusy: false
    // How much the icon darkens under the pointer while it is the link.
    // A darkening of whatever colour it has, not a colour of its own: a
    // finished row's icon already wears the category colour, and a hover
    // colour equal to it would show nothing until the click.
    property real linkHoverDarken: 1.4
    property int  linkHoverMs: 140
    readonly property bool _linkLive: row._expandFraction > 0.5 && !!row.entry && row._hasIcon

    readonly property bool _isFav: !!(entry && entry.isFavorite)

    // Full-strength when favourited, drained to near-grey otherwise. Qt's
    // color exposes hslHue/hslSaturation/hslLightness, so the hue survives the
    // drain and each category stays distinguishable even when muted.
    readonly property color _faintStripe: Qt.hsla(
        categoryColor.hslHue, row.mutedSaturation,
        row.mutedGroundColor.hslLightness
            + (0.5 - row.mutedGroundColor.hslLightness) * row.mutedLightnessMix,
        1.0)
    readonly property color _stripeColor: Mix.c(row._faintStripe, row.categoryColor, row._favF)

    // COLOUR STATE, AS FRACTIONS.
    //
    // The stripe, the fill and the icon each pick between themed colours, and
    // easing that with `Behavior on color` would not work: a Behavior cannot tell
    // a state change from the theme moving underneath it, so on a light/dark
    // switch all three would chase the crossfade with a tail of their own and
    // land a quarter-second after the card they sit in -- the faint stripe
    // is the one that shows it most. Easing the FRACTION and mixing (Mix.js)
    // leaves both endpoints live: at rest the colour IS the themed one.
    property real _favF:  row._isFav ? 1 : 0
    property real _doneF: row._stepStatus === "done" ? 1 : 0
    property real _failF: row._stepStatus === "failed" ? 1 : 0
    Behavior on _favF {
        NumberAnimation { duration: row.animDuration; easing.type: row.animEasing }
    }
    Behavior on _doneF {
        NumberAnimation { duration: row.completeFadeMs; easing.type: Easing.OutCubic }
    }
    Behavior on _failF {
        NumberAnimation { duration: row.completeFadeMs; easing.type: Easing.OutCubic }
    }

    // One shared 0→1 driver for every expand-linked value, so the row height,
    // the version block and the chevron all move on the same clock instead of
    // each chasing the others through separate Behaviors.
    property real _expandFraction: expanded ? 1 : 0
    Behavior on _expandFraction {
        NumberAnimation { duration: row.animDuration; easing.type: row.animEasing }
    }

    // The group's chevron, on its own fraction (one clock for the one motion).
    property real _openF: row.groupOpen ? 1 : 0
    Behavior on _openF {
        NumberAnimation { duration: row.animDuration; easing.type: row.animEasing }
    }

    // 0..1. The destination of a favourite flight starts at 0 and opens as the
    // clone approaches, so the gap appears to be made BY the arriving row
    // rather than waiting for it. 1 everywhere else.
    property real revealFraction: 1
    implicitHeight: (textCol.implicitHeight + vPad * _s * 2) * row.revealFraction

    // No hover wash. The cursor already changes to a pointing hand over
    // anything clickable, which is the affordance; a highlight on top of that
    // is redundant decoration.

    // The stripe IS the progress bar.
    //
    // It already exists on every row and header, it already carries the
    // category colour, and during a run favourites are irrelevant — so rather
    // than washing the row in a translucent overlay, the stripe fills from its
    // faint resting colour to the full category colour, top to bottom.
    //
    // The filled part is a rounded rectangle sharing the stripe's own corner
    // radius, so its lower edge bulges outward exactly like the cap it will
    // eventually meet at the bottom. No clipping is involved: clipping would
    // give a flat edge, which is the thing being avoided.
    Rectangle {
        id: stripe
        x: row.sidePadding * row._s
        y: row.vPad * row._s
        width: row.stripeWidth * row._s
        height: Math.max(0, row.implicitHeight - row.vPad * row._s * 2)
        radius: row.stripeWidth * row._s / 2
        // A favourite keeps its colour in a run too (it only IS a favourite
        // before the download, where nothing has happened to it yet); every
        // other row rests faint and fills as its progress arrives.
        // Eased through `_favF`, so the favourite flight can still drive the
        // change mid-flow (the host animates isFavorite at lift time).
        color: row._stripeColor
        opacity: row.contentVisible ? 1 : 0

        Rectangle {
            id: stripeFill
            // Stays while the fraction is still running back down: a row that
            // is told it is not done after all (the AUR half's built packages
            // when pacman takes them) must RETRACT on the same 280ms clock it
            // filled on, not blink out in one frame.
            visible: row.inRun && (row.stripeProgress > 0 || stripeFill._frac > 0.001)
            x: 0
            y: 0
            width: parent.width
            // The FRACTION eases, not the height. Easing the height would make the
            // fill lag the faint stripe whenever the row itself changes size
            // -- expanding a finished row would grow the faint line first and the
            // colour catch up after -- while a progress tick still needs
            // its slide. Sized from the fraction, a row-size change moves
            // both together and only progress moves the fill on its own.
            property real _frac: row.stripeProgress
            Behavior on _frac {
                NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
            }
            // Never shorter than its own cap, or the rounded end degenerates
            // into a sliver at low progress.
            height: Math.max(width, parent.height * _frac)
            radius: width / 2
            color: Mix.c(row.categoryColor, row.errorColor, row._failF)
        }
    }

    Text {
        id: iconLabel
        visible: row._hasIcon
        text: row.iconGlyph
        font.family: row.iconFontFamily
        font.pixelSize: row._iconSize
        // Colourless at rest; takes the full category colour once its package
        // is finished. That is the completion mark — the stripe carries the
        // progress, so this only ever reports done or not done.
        color: Mix.c3(Mix.c(row.mutedColor, row.faintColor, row.iconTone),
                      row.categoryColor, row._doneF,
                      row.errorColor, row._failF)
        opacity: row.contentVisible ? 1 : 0
        // Busy: a slow breathe, so "waiting" reads as motion rather than as
        // a disabled icon. Restored to full when the wait ends.
        SequentialAnimation on opacity {
            id: linkPulse
            running: row.linkBusy && row.contentVisible
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutSine }
            onRunningChanged: if (!linkPulse.running) iconLabel.opacity = row.contentVisible ? 1 : 0
        }

        // The hover: the same glyph, darker, fading in over the icon while
        // the pointer is on it and the row is expanded. Its own layer with
        // its own short fade, so it never fights the completion mark's
        // slower colour change on the icon itself.
        // Built only while the icon actually IS the link -- which is while
        // the row is expanded, one row at a time. A second full Text
        // on all 69 rows would re-shape the glyph whenever the font changes
        // (every view switch) to draw something with opacity 0.
        Loader {
            anchors.fill: parent
            active: row._linkLive
            sourceComponent: Text {
                text: iconLabel.text
                font: iconLabel.font
                color: Qt.darker(iconLabel.color, row.linkHoverDarken)
                opacity: row._linkLive && iconArea.containsMouse && !row.linkBusy ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: row.linkHoverMs } }
            }
        }
        // Centred in the slot so growing does not shift the text.
        x: (row.sidePadding + row.stripeWidth + 8) * row._s
           + (row._iconSlot - row.iconGap * row._s - implicitWidth) / 2
        y: row.vPad * row._s
           + (row.implicitHeight - row.vPad * row._s * 2 - implicitHeight) / 2
    }

    // Built only while yay is actually parked at a numbered prompt, which is
    // a few seconds of a run. Outside that the number takes no space (the
    // slot is zero-width) and shows nothing, but a Text kept on
    // every row would re-shape its digits at a new pixel size on every view
    // switch. `_numberReveal > 0` rather than `_hasNumber` so the item
    // survives its own fade-out.
    Loader {
        active: row._hasNumber || row._numberReveal > 0
        sourceComponent: Text {
            id: numberLabel
            visible: row._numberReveal > 0
            // Keeps the last digit while fading out, so a vanishing number does
            // not blink to 0 on its way.
            text: row.packageNumber > 0 ? row.packageNumber : text
            color: row.numberColor
            font.family: row.fontFamily
            font.pixelSize: row._numberSize
            font.bold: true
            opacity: row.contentVisible ? row._numberReveal : 0
            horizontalAlignment: Text.AlignHCenter
            // Sits between the icon and the text, centred in its own slot so it
            // does not shift the name as the number gains a digit.
            x: (row.sidePadding + row.stripeWidth + 8) * row._s + row._iconSlot
               + (row._numberSlot - row.numberGap * row._s - implicitWidth) / 2
            y: row.vPad * row._s
               + (row.implicitHeight - row.vPad * row._s * 2 - implicitHeight) / 2
        }
    }

    Column {
        id: textCol
        x: row.padLeft
        y: row.vPad * row._s
        width: row.width - row.padLeft - row.padRight * row._s - (row.isGroup ? groupChevron.width + 8 * row._s : 0)
        spacing: 1
        opacity: row.contentVisible ? 1 : 0

        Text {
            id: nameText
            text: row.entry ? row.entry.name : ""
            color: row.textColor
            font.pixelSize: row.nameSize * row._s
            font.family: row.fontFamily
            font.bold: true
            width: parent.width
            elide: Text.ElideRight
        }

        // Replaces the version line while the row is active, because that is
        // when the live figure matters more than the version you already know
        // you are moving to. Reverts the moment the row finishes.
        //
        // Only a run ever has a detail to show, so the idle list -- which is
        // what is on screen for all but a few minutes of the shell's life,
        // and what the user expands and switches views on -- carries none of
        // these. Gated on `inRun` rather than on the text being non-empty:
        // that flips per row several times during a run, and churning the
        // item would cost more than keeping it.
        Loader {
            active: row.inRun
            visible: row._liveDetail.length > 0
            width: parent.width
            sourceComponent: Text {
                id: liveDetail
                text: row._liveDetail
                color: row.categoryColor
                font.pixelSize: row.versionSize * row._s
                font.family: row.fontFamily
                width: parent.width
                elide: Text.ElideRight
            }
        }

        // BUILT ONLY DURING A RUN.
        //
        // DownloadStats is fourteen items, a FontMetrics and a table of
        // measured digit widths, and it can only ever be SEEN while bytes are
        // moving -- `_showStats` requires a step status, which only a run
        // gives. Built unconditionally it would be the largest single thing every
        // row carries: 69 of them in the idle list, each measuring ten digit
        // advances at creation and re-measuring the whole slot table whenever
        // the list scale changes -- what a view switch would pay for.
        //
        // Gated on `inRun`, not on `_showStats`: the visibility flips per row
        // several times during a download, and creating and destroying the
        // block on each flip would trade a steady cost for a jerky one. One
        // creation per row per run, then `visible` does exactly what it did.
        // The Loader carries the visibility so the Column still skips it.
        Loader {
            id: liveStats
            active: row.inRun
            visible: row._showStats
            width: parent.width
            sourceComponent: DownloadStats {
            alignment: row.statsAlignment
            showPackages: false
            bytesDone: row._stepStatus === "pending" ? -1 : row.dlBytes * row.dlPct / 100
            bytesTotal: row.dlBytes
            rateText: row.dlRate
            etaText: row.dlEta
            // Live figures in the category's colour; a waiting row's size
            // in the version line's muted tone, since nothing is moving.
            color: row._stepStatus === "pending" ? row.mutedColor : row.categoryColor
            fontFamily: row.fontFamily
            pixelSize: (row.compactStats ? row.statsSizeCompact : row.versionSize) * row._s
            separatorGap: 5 * row._s
            width: liveStats.width
            // Sooner drop the rate than cut the ETA off the end.
            availableWidth: liveStats.width
            }
        }

        FromToPair {
            id: versions
            // From the inputs, not the siblings' `visible`: that reads back
            // effective visibility, which is false whenever the row is.
            visible: row._liveDetail.length === 0 && !row._showStats
            primaryText: row.isGroup ? row.groupLine : (row.entry ? (row.entry.newVer || "") : "")
            secondaryText: row.isGroup ? "" : (row.entry ? (row.entry.oldVer || "") : "")
            expandFraction: row._expandFraction
            secondaryPosition: "below"
            stackedGap: 14 * row._s
            inlineGap: 8 * row._s
            primaryColor: row.mutedColor
            secondaryColor: row.faintColor
            connectorColor: row.faintColor
            fontFamily: row.fontFamily
            fontPixelSize: row.versionSize * row._s
            width: parent.width
        }
    }

    // No per-row expand chevron: the row is the affordance (whole row is
    // clickable) and the version reveal is its own feedback. A chevron on
    // every row added a column of visual noise for no extra information.

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                row.toggleFavoriteRequested();
            } else if (row.isGroup) {
                row.activated();
            } else {
                row.expanded = !row.expanded;
            }
        }
    }

    // The group's chevron: down shut, up open, in the notification bundle's mark. Placed by hand on
    // whole pixels, and under the row-wide MouseArea's click like everything else on the row.
    Chevron {
        id: groupChevron
        visible: row.isGroup
        size: row.chevronSize * row._s
        thickness: 1.5
        color: row.faintColor
        opacity: row.contentVisible ? 1 : 0
        rotation: row._openF * 180
        x: Math.round(row.width - row.padRight * row._s - width)
        y: Math.round((row.implicitHeight - height) / 2)
    }

    // Declared AFTER the row-wide MouseArea, so it sits above it: a left
    // click on the icon of an expanded row is the link and never reaches
    // the toggle. Right click is not accepted and falls through to the
    // favourite toggle, the same as anywhere else on the row. Collapsed,
    // this area is off and the icon is inert.
    MouseArea {
        id: iconArea
        objectName: "updateLinkArea"
        enabled: row._linkLive
        visible: row._linkLive
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        // A hit box comfortably bigger than the glyph, centred on it.
        readonly property real hit: Math.max(row._iconSize + 8 * row._s, 18)
        width: hit
        height: hit
        x: iconLabel.x + (iconLabel.implicitWidth - width) / 2
        y: iconLabel.y + (iconLabel.implicitHeight - height) / 2
        cursorShape: row.linkBusy ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!row.linkBusy) row.openUrlRequested()
    }
}
