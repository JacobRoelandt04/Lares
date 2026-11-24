pragma ComponentBehavior: Bound

import QtQuick

import "../components/AppHue.js" as AppHue

// =============================================================================
// IconColours.qml -- an icon's strongest colour, sampled once (the per-app colour of screentime comes from the
// icon at run time; nothing is baked).
//
//   IconColours { id: colours }
//   colours.serial; colours.colourOf(source)      // a colour, or null: not sampled yet, or the icon has none
//   colours.want(source)                          // asks for a sample (an image source: AppIcon.source)
//
// HOW CHEAP. The icon is drawn at 16 x 16 into a Canvas (`Canvas.Image`, cooperative, always visible at opacity 0: toggling `visible`
// on a cooperative Canvas costs a garbage frame, CLAUDE.md), read back as 1 KB of pixels and reduced by AppHue.sample(): 256 pixels
// of arithmetic. Every icon waiting is sampled in ONE paint, an icon is sampled once per session (the answer is AppHue's, shared by
// every host), and nothing is asked until an app is listed. want() only queues: it changes no property a binding reads, so it may be
// called from a binding; the answer arrives with `serial`, a turn later.
// =============================================================================
Item {
    id: root

    // Bumps when a sample has landed.
    readonly property int serial: root._serial
    property int _serial: 0
    // How many samples this host has taken (a probe's instrument; a var mutated in place, nothing bound reads it).
    readonly property var counters: ({ samples: 0, paints: 0, paintMsMax: 0 })

    property var _wanted: ({})
    property var _order: []

    function colourOf(url: string): var {
        root._serial;
        const c = AppHue.colourFor(url);
        return c ? Qt.rgba(c.r, c.g, c.b, 1) : null;
    }
    // True once `url` has been sampled (its colour may still be null: the icon has none).
    function sampled(url: string): bool {
        root._serial;
        return AppHue.known(url);
    }

    function want(url: string): void {
        if (url === "" || AppHue.known(url) || root._wanted[url] === true)
            return;
        root._wanted[url] = true;
        root._order.push(url);
        // Never in the call itself: a card asks while it is being BUILT, when the Canvas has no window to load an image into (a
        // loadImage then takes the whole process down with a segfault); the next turn of the loop is after every item is complete.
        kick.restart();
    }
    Timer {
        id: kick
        interval: 0
        onTriggered: {
            for (const u of root._order)
                if (root._loading[u] !== true) {
                    root._loading[u] = true;
                    cv.loadImage(u);
                }
            cv.requestPaint();
        }
    }
    property var _loading: ({})

    width: 16
    height: 16
    opacity: 0
    enabled: false

    // scale-ok: never drawn on screen (opacity 0); it is a 16 x 16 read-back of an icon's pixels, which is the same at every scale
    Canvas {
        id: cv
        width: 16
        height: 16
        renderStrategy: Canvas.Cooperative
        renderTarget: Canvas.Image
        onImageLoaded: cv.requestPaint()
        onPaint: {
            root.counters.paints++;
            const t0 = Date.now();
            const ctx = cv.getContext("2d");
            let took = false;
            const rest = [];
            for (let i = 0; i < root._order.length; i++) {
                const url = root._order[i];
                if (!cv.isImageLoaded(url)) {
                    // An icon that cannot be loaded (a file gone) is sampled as "no colour", not waited for for ever.
                    if (cv.isImageError(url)) {
                        AppHue.remember(url, null);
                        took = true;
                    } else {
                        rest.push(url);
                    }
                    continue;
                }
                ctx.reset();
                ctx.clearRect(0, 0, 16, 16);
                ctx.drawImage(url, 0, 0, 16, 16);
                AppHue.remember(url, AppHue.sample(ctx.getImageData(0, 0, 16, 16).data));
                root.counters.samples++;
                took = true;
            }
            root._order = rest;
            root.counters.paintMsMax = Math.max(root.counters.paintMsMax, Date.now() - t0);
            if (took)
                root._serial++;
        }
    }
}
