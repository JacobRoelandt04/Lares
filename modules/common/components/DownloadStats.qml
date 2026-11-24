pragma ComponentBehavior: Bound

import QtQuick
import "Bytes.js" as Bytes

// =============================================================================
// DownloadStats.qml
//
// A line of download figures that does not jitter:
//
//     12 / 20 packages  ·  123.4 / 741.2 MiB  ·  10.1 MiB/s  ·  01:13
//
// Built as one string, every tick would re-measure the whole thing and the
// text to the LEFT of any number that changed width would slide sideways to
// make room. Here each figure is its own Text inside a slot of FIXED width, measured
// from a template at the current font ("000.0" to the total's digit count,
// "00.0 MiB/s" to the rate's own character count, "00:00", the total's own
// text), so a value gaining or losing a digit moves nothing outside its
// slot. The block only ever re-shapes when a whole metric appears or
// disappears -- or, for the rate, when it crosses a digit count.
//
// The slack a slot has over a typical value (Audiowide's "0" is 2.6x the
// width of its "1") sits on the number's open side: before a right-aligned
// figure, so the gap after a separator breathes a little. That is the
// price of the fixed anchors, and it is a gap, not a shift.
//
// Inside each slot the number is aligned so the characters that change most
// sit against a fixed edge, or move nothing:
//
//   done            right, against the fixed " / total unit"
//   bytes done      right, against the fixed " / total": the unit and the
//                   decimal digit hold still; only the leading digits breathe
//   rate            right: "MiB/s" holds still against the next separator
//   eta             LEFT: the seconds' units digit is the one that changes
//                   every tick and it is the LAST character, so with the
//                   text pinned at its left nothing to its left can move.
//
// Templates use the font's WIDEST digit, so a slot fits any value of that
// digit count: Audiowide's "0" is 2.6x the width of its "1". Fonts that carry
// tabular figures get them switched on as well (`tabularFigures`), which
// removes even the within-slot breathing; Audiowide has no such table, so
// there the slots are what does the work.
//
// A slot never clips. A value wider than its template (a 1000-1023.9 KiB
// rate, an ETA with hours) simply widens the slot for as long as it lasts.
//
// `availableWidth` lets a host that is short of room say so: when the block
// with its rate would overrun it, the rate -- the least useful figure -- is
// dropped rather than the ETA being elided.
//
//   DownloadStats {
//       anchors.right: parent.right
//       done: 12; total: 20
//       bytesDone: 129400000; bytesTotal: 777150000
//       rateText: "10.1 MiB/s"; etaText: "01:13"
//   }
// =============================================================================
Item {
    id: stats

    // ---- Values --------------------------------------------------------------
    // "done / total unit". Hidden while total <= 0.
    property int done: -1
    property int total: -1
    property string unit: "packages"
    // The unit agrees with the TOTAL, which is the figure it is written
    // against: "1 package", "0 / 1 package", "0 / 7 packages". A fixed plural
    // would say "1 packages" at the AUR transaction's Proceed question, and a
    // one-package transaction is the common case there. A unit whose singular
    // is not simply one "s" fewer gives it here.
    property string unitSingular: ""
    readonly property string _unitText: stats.total !== 1 ? stats.unit
        : (stats.unitSingular.length > 0 ? stats.unitSingular
           : (stats.unit.length > 1 && stats.unit.charAt(stats.unit.length - 1) === "s"
              ? stats.unit.substring(0, stats.unit.length - 1) : stats.unit))
    // "123.4 / 741.2 MiB": the total through Bytes.formatBytes, the done
    // figure in the total's unit -- so it only ever changes digits, never
    // its unit, and its slot can be sized to the total's own digit count.
    // Hidden while bytesTotal <= 0.
    property real bytesDone: 0
    property real bytesTotal: 0
    // Already formatted, as pacman prints them: "10.1 MiB/s", "01:13".
    // Hidden while empty.
    property string rateText: ""
    property string etaText: ""

    // ---- Which figures to show -----------------------------------------------
    property bool showPackages: true
    property bool showBytes: true
    property bool showRate: true
    property bool showEta: true
    // Width the host can give the block. When the block with its rate would
    // be wider than this the rate is left out.
    // Room the block may take before it drops the rate. -1 (the default) is
    // "no constraint"; any other value is taken literally, so a host that
    // computes it must not hand over a negative by accident.
    property real availableWidth: -1

    // ---- Layout --------------------------------------------------------------
    // Which edge of the item the figures are pinned to. Qt.AlignRight for a
    // block that sits at the end of a line (its right edge is what the eye
    // aligns to, so that is the edge that must hold still); Qt.AlignLeft for
    // one that starts a line. Qt.AlignHCenter is accepted too.
    property int alignment: Qt.AlignRight
    // Clearance either side of a separator, in px at the current font.
    property real separatorGap: 5
    property string separator: "·"

    // ---- Styling -------------------------------------------------------------
    property string fontFamily: "Inter"
    property real pixelSize: 11
    property color color: "#8A8A8C"
    property color separatorColor: color
    // Ask the font for tabular figures. Harmless where the font has none.
    property bool tabularFigures: true

    readonly property var _features: tabularFigures ? ({ "tnum": 1 }) : ({})

    FontMetrics {
        id: fm
        font.family: stats.fontFamily
        font.pixelSize: stats.pixelSize
        font.features: stats._features
    }

    // ---- Templates -----------------------------------------------------------
    //
    // Each reads `fm.font` first so it is re-measured when the font changes;
    // advanceWidth is a call, and a call alone leaves the binding with
    // nothing to watch.
    readonly property string _wideDigit: {
        const f = fm.font;
        let best = "0", bw = 0;
        for (const d of "0123456789") {
            const w = fm.advanceWidth(d);
            if (w > bw) { bw = w; best = d; }
        }
        return best;
    }
    // The total, formatted once, and the done figure in its unit. Whole
    // bytes get no decimal, matching Bytes.formatBytes.
    readonly property string _totalText: bytesTotal > 0 ? Bytes.formatBytes(bytesTotal) : ""
    readonly property string _totalUnit: _totalText.substring(_totalText.lastIndexOf(" ") + 1)
    readonly property real _totalMult:
        ({ B: 1, KiB: 1024, MiB: 1048576, GiB: 1073741824, TiB: 1099511627776 })[_totalUnit] || 1
    // A negative `bytesDone` (or `done`) means "no done figure": the block
    // shows the total alone -- "11.5 MiB", "7 packages" -- for a step that
    // is known but has not touched anything yet.
    readonly property bool _bytesTotalOnly: bytesDone < 0
    readonly property bool _countTotalOnly: done < 0
    // A left-pinned block keeps its FIRST figure flush with the left edge,
    // so it lines up with a title above it. The number sits in a slot like
    // every other figure and is aligned LEFT inside it: the first glyph stays
    // flush, and the slack breathes in the gap before " / total" instead of
    // shoving the total, the rate and the time about. (Giving the number its
    // OWN width instead of a slot would move everything to its right whenever
    // the number changed width, which with a face whose "0" is 2.6x its "1"
    // is on most ticks.)
    readonly property bool _leftFlush: alignment === Qt.AlignLeft
    readonly property bool _bytesLeadsLeft: _leftFlush && !_pkgOn
    readonly property string _doneText: {
        if (stats.bytesTotal <= 0 || stats._bytesTotalOnly) return "";
        const v = Math.max(0, Math.min(stats.bytesDone, stats.bytesTotal)) / stats._totalMult;
        return stats._totalUnit === "B" ? String(Math.round(v)) : v.toFixed(1);
    }
    // As many integer digits as the total's number: done shares its unit and
    // can never exceed it, so it can never need more.
    readonly property real _bytesSlot: {
        const f = fm.font;
        const D = stats._wideDigit;
        const num = stats._totalText.split(" ")[0];
        const intDigits = Math.max(1, num.split(".")[0].length);
        const tpl = D.repeat(intDigits) + (num.indexOf(".") >= 0 ? "." + D : "");
        return Math.ceil(fm.advanceWidth(tpl));
    }
    // The rate's slot is a CHARACTER-count bucket: the numeric part of the
    // current text with every character swapped for the widest digit ("6.0"
    // -> "000", "10.5" -> "0000", "1024" -> "0000"), plus the text's own unit.
    // The slot therefore changes only when the value gains or loses a
    // character -- the rare crossing of 10 MiB/s -- and within a bucket
    // nothing left of the rate moves. Swapping only the DIGITS would keep the
    // dot, so "4.69" and "1310" would be different slots and the card's figures
    // would shift when a rate crossed from MiB/s to KiB/s. Sizing every rate for
    // "000.0 MiB/s" would leave a 20 px hole after the separator while the
    // value was 6.0 MiB/s.
    //
    // The UNIT is sized for the widest of pacman's four, whatever the value
    // is wearing: a rate that drops from MiB/s to KiB/s keeps its slot, and
    // the value -- right-aligned in it -- gives up the K/M difference on its
    // own open side rather than pulling the separator and every figure left
    // of it along by two pixels.
    readonly property real _rateSlot: {
        const f = fm.font;
        const D = stats._wideDigit;
        const m = stats.rateText.match(/^\s*(-?[\d.,]+)(.*)$/);
        if (!m) return 0;
        const num = fm.advanceWidth(m[1].replace(/[\d.,]/g, D));
        let unit = fm.advanceWidth(m[2]);
        for (const u of [" B/s", " KiB/s", " MiB/s", " GiB/s"])
            unit = Math.max(unit, fm.advanceWidth(u));
        return Math.ceil(num + unit);
    }
    // "DD:DD". An ETA with hours widens the slot for as long as it has them.
    readonly property real _etaSlot: {
        const f = fm.font;
        const D = stats._wideDigit;
        return Math.ceil(fm.advanceWidth(D + D + ":" + D + D));
    }
    // As many digits as the total has; done can never have more.
    readonly property real _countSlot: {
        const f = fm.font;
        if (stats.total <= 0) return 0;
        return Math.ceil(fm.advanceWidth(stats._wideDigit.repeat(String(stats.total).length)));
    }
    readonly property real _sepWidth: {
        const f = fm.font;
        return Math.ceil(fm.advanceWidth(stats.separator)) + stats.separatorGap * 2;
    }

    // ---- What is on the line -------------------------------------------------
    readonly property bool _pkgOn:   showPackages && total > 0
    readonly property bool _bytesOn: showBytes && bytesTotal > 0
    readonly property bool _rateWanted: showRate && rateText.length > 0
    readonly property bool _etaOn:   showEta && etaText.length > 0

    // Widths of each figure as it would be laid out, whether shown or not,
    // so the fit decision below cannot feed back into itself. Measured with
    // the metrics, never read back from a Text's width or implicitWidth:
    // those are what the Texts are SIZED from, and reading them here closed
    // a binding loop on the Text's width.
    function _w(t) { const f = fm.font; return t.length > 0 ? Math.ceil(fm.advanceWidth(t)) : 0; }
    readonly property string _pkgTailText:
        (_countTotalOnly ? "" : " / ") + total + (_unitText.length > 0 ? " " + _unitText : "")
    readonly property string _bytesTailText: (_bytesTotalOnly ? "" : " / ") + _totalText
    readonly property real _doneSlotW: _countTotalOnly ? 0
        : Math.max(_countSlot, _w(String(done)))
    readonly property real _bytesDoneSlotW: _bytesTotalOnly ? 0
        : Math.max(_bytesSlot, _w(_doneText))
    readonly property real _rateLabelW: Math.max(_rateSlot, _w(rateText))
    readonly property real _etaLabelW:  Math.max(_etaSlot, _w(etaText))
    readonly property real _pkgW:   _pkgOn   ? _doneSlotW + _w(_pkgTailText)   : 0
    readonly property real _bytesW: _bytesOn ? _bytesDoneSlotW + _w(_bytesTailText) : 0
    readonly property real _rateW:  _rateWanted ? _rateLabelW : 0
    readonly property real _etaW:   _etaOn   ? _etaLabelW : 0

    function _lineWidth(withRate) {
        const parts = [stats._pkgW, stats._bytesW, withRate ? stats._rateW : 0, stats._etaW]
            .filter(w => w > 0);
        return parts.reduce((a, b) => a + b, 0) + Math.max(0, parts.length - 1) * stats._sepWidth;
    }
    // A NEGATIVE availableWidth is the sentinel for "the host set no
    // constraint" (the default is -1), and a host that computes one by
    // subtraction can produce a negative by accident -- which then reads as
    // "unconstrained" at the exact moment there is no room, so the block
    // takes the MOST width when the line is tightest. The sentinel is the
    // default value alone; anything else is clamped at zero, where "no room" means "drop the rate".
    readonly property real _roomForRate: stats.availableWidth === -1
        ? Number.POSITIVE_INFINITY : Math.max(0, stats.availableWidth)
    readonly property bool _rateOn: _rateWanted
        && stats._lineWidth(true) <= stats._roomForRate

    // Separators sit only BETWEEN figures that are showing.
    readonly property bool _sepAfterPkg:   _pkgOn   && (_bytesOn || _rateOn || _etaOn)
    readonly property bool _sepAfterBytes: _bytesOn && (_rateOn || _etaOn)
    readonly property bool _sepAfterRate:  _rateOn  && _etaOn

    readonly property bool hasContent: _pkgOn || _bytesOn || _rateOn || _etaOn

    implicitWidth: stats._lineWidth(stats._rateOn)
    implicitHeight: fm.height
    // So a host can anchor this block's baseline to a neighbouring Text.
    baselineOffset: fm.ascent

    Row {
        id: line
        spacing: stats.separatorGap
        y: 0
        // The pinned edge is the whole point: a right-pinned block keeps its
        // right edge where it is when a figure comes or goes. Placed by x
        // rather than anchors so a change of alignment cannot leave a stale
        // anchor behind.
        x: stats.alignment === Qt.AlignRight ? stats.width - width
         : stats.alignment === Qt.AlignHCenter ? (stats.width - width) / 2
         : 0

        // -- done / total unit --
        Item {
            visible: stats._pkgOn
            width: stats._pkgW
            height: fm.height
            Text {
                id: doneText
                text: stats._countTotalOnly ? "" : String(stats.done)
                width: stats._doneSlotW
                // Flush left in a left-pinned block: the slot holds the
                // width, the text holds the edge.
                horizontalAlignment: stats._leftFlush ? Text.AlignLeft : Text.AlignRight
                color: stats.color
                font.family: stats.fontFamily
                font.pixelSize: stats.pixelSize
                font.features: stats._features
            }
            Text {
                id: pkgTail
                x: doneText.width
                text: stats._pkgTailText
                color: stats.color
                font.family: stats.fontFamily
                font.pixelSize: stats.pixelSize
                font.features: stats._features
            }
        }
        Text {
            visible: stats._sepAfterPkg
            text: stats.separator
            color: stats.separatorColor
            font.family: stats.fontFamily
            font.pixelSize: stats.pixelSize
        }

        // -- bytes done / bytes total --
        Item {
            visible: stats._bytesOn
            width: stats._bytesW
            height: fm.height
            Text {
                id: bytesDoneText
                text: stats._doneText
                width: stats._bytesDoneSlotW
                horizontalAlignment: stats._bytesLeadsLeft ? Text.AlignLeft : Text.AlignRight
                color: stats.color
                font.family: stats.fontFamily
                font.pixelSize: stats.pixelSize
                font.features: stats._features
            }
            Text {
                id: bytesTail
                x: bytesDoneText.width
                text: stats._bytesTailText
                color: stats.color
                font.family: stats.fontFamily
                font.pixelSize: stats.pixelSize
                font.features: stats._features
            }
        }
        Text {
            visible: stats._sepAfterBytes
            text: stats.separator
            color: stats.separatorColor
            font.family: stats.fontFamily
            font.pixelSize: stats.pixelSize
        }

        // -- rate --
        Text {
            id: rateLabel
            visible: stats._rateOn
            text: stats.rateText
            width: stats._rateLabelW
            horizontalAlignment: Text.AlignRight
            color: stats.color
            font.family: stats.fontFamily
            font.pixelSize: stats.pixelSize
            font.features: stats._features
        }
        Text {
            visible: stats._sepAfterRate
            text: stats.separator
            color: stats.separatorColor
            font.family: stats.fontFamily
            font.pixelSize: stats.pixelSize
        }

        // -- eta --
        Text {
            id: etaLabel
            visible: stats._etaOn
            text: stats.etaText
            width: stats._etaLabelW
            horizontalAlignment: Text.AlignLeft
            color: stats.color
            font.family: stats.fontFamily
            font.pixelSize: stats.pixelSize
            font.features: stats._features
        }
    }
}
