pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/stocks"

// =============================================================================
// tools/dev/qml/stocks_header_probe.qml -- the stock detail's header: the scrub's
// date can never reach the facts line, and the range's move sits where it should
// (tools/dev/stocks_header_probe.sh runs it). Prints SH lines and "SH RESULT PASS|FAIL".
//
// The case the user saw: a SHORT price (so the right block is as narrow as it
// gets) and a LONG exchange name, scrubbed on a range whose date is the longest
// format. Every weekday x month is tried for the date; none may be elided, and
// the date's left edge stays at or right of the facts line's right edge.
//
// THE TEXTS' ROOM (the user, 2026-11-23: title and facts cut with room to spare):
// a long name ends 10 px before the PRICE's slot (not the change line's), a long
// facts line 10 px before the change line's block, each on every range; the
// scrub's date clears the facts line and moves nothing on EVERY range.
// =============================================================================
Scope {
    id: root
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("SH " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 520
        implicitHeight: 140
        color: Theme.surface
        StockDetailHeader {
            id: head
            x: 12
            y: 12
            width: 456
            height: implicitHeight
            symbol: "AAPL"
            fontFamily: "Inter"
            quote: ({ name: "Apple Inc.", price: 97.12, change: 0.8, changePct: 0.83, currency: "USD", priceHint: 2,
                      fullExchange: "Nasdaq Global Select Market", state: "open" })
            range: "1M"
            fig: ({ symbol: "AAPL", range: "1M", change: 4.1, pct: 4.4 })
            bound: ({ abs: 12.5, pct: 13.2 })
        }
    }
    function find(name: string): var {
        const kids = head.children;
        for (let i = 0; i < kids.length; i++)
            if (kids[i].objectName === name)
                return kids[i];
        return null;
    }
    function facts(): var {
        for (let i = 0; i < head.children.length; i++) {
            const c = head.children[i];
            if (c.text !== undefined && String(c.text).indexOf("AAPL ·") === 0)
                return c;
        }
        return null;
    }
    function t(y: int, m: int, d: int): real {
        return new Date(y, m, d, 23, 59).getTime();
    }

    property int step: 0
    Timer {
        interval: 600
        running: true
        onTriggered: root.run()
    }
    function run() {
        const date = root.find("stockDetailDate"), label = root.find("stockDetailRangeLabel"), change = root.find("stockDetailChange");
        const f = root.facts();
        root.check("parts exist", !!date && !!label && !!change && !!f, "date=" + date + " label=" + label + " change=" + change + " facts=" + f);
        if (!date || !label || !change || !f) {
            console.log("SH RESULT FAIL (parts missing)");
            Qt.quit();
            return;
        }
        // 1. at rest on 1M: the range's name and move, the amount in its slot
        root.check("1M label", label.text === "1M", label.text);
        root.check("1M amount is the range's", change.text === "+4.10", change.text);
        root.check("label sits left of the amount", label.x + label.width <= change.x, label.x + "+" + label.width + " vs " + change.x);
        root.check("no date at rest", !date.visible && change.visible, "date " + date.visible + " change " + change.visible);
        const restX = change.x;
        // 2. 1D has no label and today's move
        head.range = "1D";
        head.fig = { symbol: "AAPL", range: "1D", change: 3, pct: 3 };
        root.check("1D unlabelled", label.text === "", label.text);
        root.check("1D amount is today's", change.text === "+0.80", change.text);
        // 3. a figure that belongs to another stock is not ours
        head.range = "1M";
        head.fig = { symbol: "MSFT", range: "1M", change: 99, pct: 99 };
        root.check("another stock's figure ignored", label.text === "" && change.text === "+0.80", label.text + "|" + change.text);
        head.fig = { symbol: "AAPL", range: "1M", change: -2.5, pct: -2.6 };
        root.check("a loss reads with the true minus", change.text === "−2.50", change.text);
        // 4. every date the longest format can print, scrubbed: never elided, never into the facts
        const factsRight = f.x + f.width;
        let worst = 0, bad = "";
        for (let m = 0; m < 12; m++)
            for (let d = 1; d <= 7; d++) {
                head.scrub = { v: 98, t: root.t(2026, m, d + 1 + (m % 3) * 7), base: 90 };
                const left = date.x + date.width - date.contentWidth;
                worst = Math.max(worst, date.contentWidth);
                if (date.truncated || left < factsRight || date.x < factsRight)
                    bad += " " + date.text + (date.truncated ? "(cut)" : "") + "@" + Math.round(left);
            }
        root.check("the scrub's date clears the facts line", bad === "", "facts end " + factsRight + ", date slot " + date.x + ".." + (date.x + date.width) + " worst " + worst + ":" + bad);
        root.check("scrub shows the date, not the amount", date.visible && !change.visible && label.text === "", "date " + date.visible + " change " + change.visible + " label " + label.text);
        root.check("the amount's slot did not move", change.x === restX, change.x + " vs " + restX);
        head.scrub = null;
        root.check("scrub ends: amount back", !date.visible && change.visible, "");
        // 5. the texts' room: a long name and a long facts line, every range
        head.symbol = "TSM";
        head.quote = { name: "Taiwan Semiconductor Manufacturing Company Limited", price: 187.4, change: 2.1, changePct: 1.13, currency: "USD",
                       priceHint: 2, fullExchange: "Nasdaq Global Select Market Long Exchange Name", state: "post", gmtoffset: -18000, tz: "America/New_York" };
        let nameF = null, factsF = null, price = null;
        for (let i = 0; i < head.children.length; i++) {
            const c = head.children[i];
            if (c.text === undefined)
                continue;
            if (String(c.text).indexOf("Taiwan") === 0)
                nameF = c;
            else if (String(c.text).indexOf("TSM ·") === 0)
                factsF = c;
            else if (c.objectName === "stockDetailPrice")
                price = c;
        }
        const ranges = ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "MAX"];
        let roomBad = "", scrubBad = "";
        for (const r of ranges) {
            head.range = r;
            head.fig = { symbol: "TSM", range: r, change: 12.4, pct: 7.1 };
            head.scrub = null;
            const priceSlot = price.x;                     // the price's slot starts here (right-aligned in it)
            const nameEnd = nameF.x + nameF.width, factsEnd = factsF.x + factsF.width;
            const lab = root.find("stockDetailRangeLabel"), amt = root.find("stockDetailChange");
            const changeBlock = Math.min(date.x, lab.x, amt.x);
            if (!nameF.truncated || Math.abs(nameEnd - (head.width - head.starW - 6 - head.priceW - 10)) > 0.5 || nameEnd > priceSlot + price.width - price.contentWidth - 10)
                roomBad += " " + r + ":name ends " + Math.round(nameEnd * 10) / 10 + " price ink " + Math.round((priceSlot + price.width - price.contentWidth) * 10) / 10;
            if (!factsF.truncated || Math.abs(factsEnd - (changeBlock - 10)) > 0.5)
                roomBad += " " + r + ":facts end " + Math.round(factsEnd * 10) / 10 + " change block " + Math.round(changeBlock * 10) / 10;
            const restAmt = amt.x;
            head.scrub = { v: 180.2, t: root.t(2026, 4, 13), base: 175 };
            if (date.truncated || date.x < factsEnd || date.x + date.width - date.contentWidth < factsEnd || amt.x !== restAmt)
                scrubBad += " " + r + ":" + date.text + (date.truncated ? "(cut)" : "") + "@" + Math.round(date.x * 10) / 10 + " facts " + Math.round(factsEnd * 10) / 10;
            head.scrub = null;
        }
        root.check("room: on every range the name ends 10 px before the price's slot and the facts 10 px before the change line's block", roomBad === "", roomBad);
        root.check("room: on every range the scrub's date clears the facts line and nothing moves", scrubBad === "", scrubBad);
        head.range = "1M";
        const gapName = price.x + price.width - price.contentWidth - (nameF.x + nameF.width);
        root.check("room: the name's room to the price's ink is the 10 px gap and the slot's spare (" + gapName.toFixed(1) + " px)", gapName >= 10 && gapName <= 24, gapName.toFixed(1));
        console.log("SH RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }
}
