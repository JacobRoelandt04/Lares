pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// WikiCarousel.qml -- the entry's pictures, one at a time, in the hero well.
//
//   photo   a pre-cropped 16:9 file (the batch cropped it around `focusY`;
//           nothing is cropped here -- PreserveAspectCrop only absorbs the
//           rounding of a 960 x 540 file into 424 x 238)
//   relief  the subject's own logo, baked as a relief (LogoRelief), centred at
//           `reliefFraction` of the well's height on a flat plate of the
//           article's veil -- systemd's mark on an ArchWiki page about it
//   veil    no picture at all: the article's veil (WikiVeil), a slow pattern
//           picked and seeded by `veilKey`. A photograph whose file does not
//           load is a veil too.
//
// ONE SLIDE, ONE CLOCK. A step (the timer, a click, a dot) starts `_t` at 0 and
// eases it to 1 over `slideMs`; the outgoing picture sits at -dir * t * width
// and the incoming one at dir * (1 - t) * width. A picture is placed by whole
// pixels. Nothing animates at rest: the auto-advance is one single Timer that
// runs only while there is somewhere to go, nobody is looking closer, and the
// host has not held it (`paused`: the pointer is over the hero, the secondary
// is moving, the popup is hidden, the theme is crossfading). A veil has its own
// clock (WikiVeil's), which runs only for the picture on show and only while
// the host says `veilRunning`.
//
// The item CLIPS to its own rectangle: a picture leaves through the well's
// straight edges. The well's ROUNDED corners are the hero's business (four
// corner pieces of the ground colour over the clip), because a rectangular clip
// cannot round.
//
// The pictures are kept by KEY (their files), not by the array's identity: a
// card rebuilt with the very same pictures (a written intro swapped in) must
// not send the carousel back to the first one.
// =============================================================================
Item {
    id: root

    property var images: []
    property WikiStyle style: WikiStyle {}
    property int autoAdvanceMs: 7000
    property int slideMs: 260
    // Held by the host: hovered, moving, hidden, crossfading.
    property bool paused: false
    // The veil of an entry with no picture: the article's id, its family's hue,
    // and whether it may move (the card is live and somebody can see it).
    property string veilKey: ""
    property color veilHue: Theme.shadowDeep
    property bool veilRunning: true

    readonly property int count: root.images ? root.images.length : 0
    readonly property int currentIndex: root._cur
    readonly property bool sliding: root._t < 1
    readonly property var current: root._cur < root.count ? root.images[root._cur] : null
    // The credit of the picture on show, "" when it has none.
    readonly property string credit: {
        const im = root.current;
        if (!im || !im.credit)
            return "";
        return im.license ? im.credit + " · " + im.license : im.credit;
    }

    // ---- what a step does -----------------------------------------------------------
    function goTo(i, dir) {
        if (root.count < 2 || i === root._cur || i < 0 || i >= root.count)
            return;
        // A slide still in flight lands where it was going before the next starts.
        slide.stop();
        root._prev = root._cur;
        root._cur = i;
        root._dir = dir !== 0 ? dir : (i > root._prev ? 1 : -1);
        root._t = 0;
        slide.start();
    }
    function step(dir) {
        if (root.count < 2)
            return;
        root.goTo(((root._cur + dir) % root.count + root.count) % root.count, dir);
    }

    // ---- state -------------------------------------------------------------------------
    property int _cur: 0
    property int _prev: -1
    property int _dir: 1
    property real _t: 1

    readonly property string _key: {
        const list = root.images || [];
        let k = "";
        for (let i = 0; i < list.length; i++)
            k += (list[i].kind || "") + ":" + (list[i].url || "") + "|";
        return k;
    }
    on_KeyChanged: {
        slide.stop();
        root._cur = 0;
        root._prev = -1;
        root._t = 1;
    }

    NumberAnimation {
        id: slide
        target: root
        property: "_t"
        from: 0
        to: 1
        duration: root.slideMs
        easing.type: Easing.OutCubic
    }

    Timer {
        interval: root.autoAdvanceMs
        repeat: true
        running: root.count > 1 && !root.paused && !root.sliding && root.visible
        onTriggered: root.step(1)
    }

    clip: true

    Repeater {
        model: root.images

        Item {
            id: pic

            required property var modelData
            required property int index

            readonly property bool _isCur: pic.index === root._cur
            readonly property bool _isPrev: pic.index === root._prev && root._t < 1
            readonly property string _kind: pic.modelData.kind || "photo"
            // No photograph to show (none, or one whose file is gone): the veil.
            readonly property bool _veiled: pic._kind !== "photo" || photo.status === Image.Error
            // A subject's logo is a LogoRelief centred on the veil's flat plate.
            readonly property real _mark: Math.round(root.height * root.style.reliefFraction)

            width: root.width
            height: root.height
            visible: pic._isCur || pic._isPrev
            x: pic._isCur ? Math.round((1 - root._t) * root._dir * root.width)
               : pic._isPrev ? Math.round(-root._t * root._dir * root.width) : 0

            Image {
                id: photo
                anchors.fill: parent
                visible: pic._kind === "photo" && !pic._veiled
                source: pic._kind === "photo" ? pic.modelData.url : ""
                fillMode: Image.PreserveAspectCrop
                // Decoded once, whole, at the file's own size: a resize must not
                // decode again, and a synchronous load leaves no blank frame
                // between two cards.
                asynchronous: false
                cache: true
                smooth: true
                mipmap: true
            }
            // Built only for a picture that needs one (a photograph has no veil under it).
            Loader {
                anchors.fill: parent
                active: pic._veiled
                sourceComponent: WikiVeil {
                    seedKey: root.veilKey
                    hue: root.veilHue
                    style: root.style.veil
                    running: root.veilRunning && pic._isCur
                    plateRadius: pic._kind === "relief" ? Math.round(pic._mark * root.style.veil.plateFraction) : 0
                }
            }
            LogoRelief {
                visible: pic._kind === "relief"
                x: Math.round((pic.width - pic._mark) / 2)
                y: Math.round((pic.height - pic._mark) / 2)
                logoSize: pic._mark
                surfaceColor: Theme.listBox
                source: pic._kind === "relief" ? pic.modelData.url : ""
            }
        }
    }
}
