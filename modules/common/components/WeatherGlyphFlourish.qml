pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// WeatherGlyphFlourish.qml -- ONE flourish clock for a card full of weather glyphs (the hourly strip's columns, the daily
// list's rows, the tiles, the detail's chips and its conditions strip).
//
// A card's glyphs flourish when the pointer comes onto their item or picks it. Each one plays to its END whatever the
// pointer does next: sweeping over a row of them leaves a wake of flourishes, none cut short by the next. So the card holds
// one clock and a RUN per glyph on it:
//
//   play(tag, beats)   starts a run for the glyph(s) the card calls `tag` (an index, a name), `beats` beats long: the glyph's
//                      own WeatherGlyph.flourishBeats (the longest, where an item has two). Nothing happens while that tag's
//                      run is still on (a hover never restarts a flourish) or for 0 beats (the carved set, no flourish).
//   a glyph binds      posing: fl.on(<its tag>)        poseBeat: fl.beatOf(<its tag>)
//                      (a glyph with no run reads only `runs`, which changes when a run starts or the clock stops: only the
//                      glyphs that play follow the clock)
//   hovered(area)      the pointer's rule for a card's MouseArea (the bar glyphs': one play per ENTRY, and only once the pointer
//                      MOVES after it): call it from onPositionChanged; true when this motion is the entry's first.
//
// The clock is the bar glyphs' (GlyphFlourish: it runs only while something plays, to the end of the last run; holds through a
// theme crossfade; registers with the OLED care so a pixel shift waits for it); it has no group, so it never plays at random.
// A single glyph under the pointer (the hero's) takes a GlyphFlourish of its own instead.
// =============================================================================
QtObject {
    id: wf

    // one beat, ms (WeatherPopup.glyphFlourishMs; the bar's is WeatherBarButton.flourishMs)
    property int beatMs: 900
    // an Item of the card (which screen the flourish is on)
    property Item host: null

    // tag -> { t0, end }: ms on the clock
    property var runs: ({})
    readonly property bool playing: wf.clock.playing

    function on(tag): bool {
        const r = wf.runs[tag];
        return r !== undefined && wf.clock.playing && wf.clock.t < r.end;
    }
    function beatOf(tag): real {
        const r = wf.runs[tag];
        return r === undefined ? 0 : Math.max(0, wf.clock.t - r.t0) / Math.max(1, wf.beatMs);
    }

    function play(tag, beats: real): bool {
        if (!(beats > 0))
            return false;
        const now = wf.clock.playing ? wf.clock.t : 0;
        const len = beats * wf.beatMs;
        const next = {};
        let need = len;
        if (wf.clock.playing) {
            for (const k in wf.runs) {
                const r = wf.runs[k];
                if (r.end <= now)
                    continue;
                if (k === String(tag))
                    return false;
                next[k] = r;
                need = Math.max(need, r.end - now);
            }
        }
        next[tag] = { t0: now, end: now + len };
        // the clock ends `_ms` after this kick: at the end of the longest run still on
        wf._ms = need;
        wf.runs = next;
        return wf.clock.play("pick");
    }

    // where the pointer entered each area (window px), until its first motion there
    property var _entries: ({})
    function entered(area: MouseArea): void {
        const p = area.mapToItem(null, area.mouseX, area.mouseY);
        wf._entries[area] = area.containsMouse ? [p.x, p.y] : null;
    }
    function hovered(area: MouseArea): bool {
        const e = wf._entries[area];
        if (!e)
            return false;
        const p = area.mapToItem(null, area.mouseX, area.mouseY);
        if (Math.abs(p.x - e[0]) + Math.abs(p.y - e[1]) < 1)
            return false;
        wf._entries[area] = null;
        return true;
    }

    property real _ms: 1
    readonly property GlyphFlourish clock: GlyphFlourish {
        host: wf.host
        hoverPlays: false
        overlap: "extend"
        ms: Math.max(1, Math.round(wf._ms))
        onFinished: wf.runs = ({})
    }
}
