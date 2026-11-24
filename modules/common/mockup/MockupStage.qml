pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../theme"
import "../scroll"

// =============================================================================
// MockupStage -- the content, centred, at its own implicit size, magnified.
//
// The stage is a panel that follows the content's implicitWidth and
// implicitHeight with an animated resize, the way thePopup grows and
// shrinks when a module changes mode; the content is anchored to fill it.
// No padding of its own: the content's padding is the only padding, so what
// the stage shows is what the content asks for.
//
// `zoom` is a render transform, not a size change: it magnifies the finished
// content, so every pixel size inside -- paddings, grooves, particle radii,
// font sizes -- keeps its true relationship to the others. Driving a size
// multiplier through the components instead would scale boxes but not text.
// The wrapper Item exists so the layout reserves the magnified size, and the
// whole thing lives in a Flickable so a zoom that outgrows the window can be
// panned instead of cut off.
// =============================================================================
Flickable {
    id: stageView

    property Item content: null
    property real zoom: 1.0
    // GROW TO THE RIGHT, rather than out of both sides at once. A stage that
    // stays centred moves its own left edge every time the content widens, so
    // a panel opening on the right drags the whole module leftwards under the
    // pointer -- which is not what the module does on the bar, where its left
    // edge is where the popup is anchored. With this on, the stage is centred
    // on the WIDEST it has been and everything narrower keeps that left edge.
    property bool anchorLeft: false
    // Cut the content to the easing surface, as the bar's engine does
    // (GooeyBody is `clip: true` at the box it animates): a content whose
    // layout changes size shows only what the popup will show while the box
    // eases after it. Off, it paints wherever it likes -- which is how the
    // weather popup's cards were seen hanging below its box, and the clock's
    // calendar poking out of a popup still growing from the timers tab.
    // With it comes the engine's HOLD (below): a clip delivers nothing
    // outside its rect, so without it a swipe that narrows the content under
    // the fingers would go deaf.
    property bool clipContent: false
    // How long the stage takes to follow a change of the content's implicit
    // size; matches thePopup's resize.
    property int resizeMs: 260
    // The popup's ground, as thePopup draws it: the theme's surface, so a
    // transparent content (the clock's) is seen on the right half of the
    // theme. A mockup that wants another ground still sets it.
    property color stageColor: Theme.surface
    property color stageBorder: Theme.border
    property real stageRadius: 22
    readonly property bool contentSized: stageView.content !== null && stageView.content.implicitWidth >= 1 && stageView.content.implicitHeight >= 1
    // The magnified content does not fit the viewport: part of it is out of
    // view (scrolled away), and a click aimed there lands on whatever is
    // beside the stage. MockupWindow.fitContent words it on the caption.
    readonly property bool contentCut: zoomHost.width > stageView.width + 0.5 || zoomHost.height > stageView.height + 0.5

    clip: true
    contentWidth: Math.max(width, zoomHost.width)
    contentHeight: Math.max(height, zoomHost.height)
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {
        policy: ScrollBar.AsNeeded
    }
    ScrollBar.horizontal: ScrollBar {
        policy: ScrollBar.AsNeeded
    }

    onContentChanged: {
        stageView._widest = 0;              // a new content is a new widest
        stageView.attach();
    }
    Component.onCompleted: stageView.attach()
    function attach() {
        if (!stageView.content)
            return;
        stageView.content.parent = stageRect;
        stageView.content.anchors.fill = stageRect;
    }

    // Where the zoomed stage would stand centred in the viewport, before it is put on a
    // whole pixel (zoomHost does that): MOCKUP_STAGE_ORIGIN prints the two side by side.
    readonly property real centreX: Math.max(0, (stageView.width - (stageView.anchorLeft ? Math.max(stageView._widest, zoomHost.width) : zoomHost.width)) / 2)
    readonly property real centreY: Math.max(0, (stageView.height - zoomHost.height) / 2)
    // The content's top-left in `target`'s coordinates: where the scene stands in a window.
    function sceneOrigin(target) {
        return stageRect.mapToItem(target, 0, 0);
    }

    // The widest the content has been, which is what `anchorLeft` centres on.
    // Reset when the content itself is swapped, and never shrunk: a stage that
    // re-centred on the narrow layout would put the left edge back.
    property real _widest: 0

    Item {
        id: zoomHost
        // Centred in the viewport while it fits; the Flickable takes over
        // once the zoom makes it larger.
        onWidthChanged: if (width > stageView._widest)
            stageView._widest = width
        // ON WHOLE WINDOW PIXELS. The real shell's window sits at the screen's origin, so
        // the scene stands on the pixel grid there; a stage centred at a half pixel
        // (at (34, 211.5), the power mockup's) put every layered body of the engine
        // (its clip layer lands on the WINDOW's grid, GooeyBody 319b4024) half a pixel off
        // the scene's own grid, so a scene grab and the window disagreed. The centring
        // offset is rounded; the stage's own position in the window is whole already.
        x: Math.round(stageView.centreX)
        y: Math.round(stageView.centreY)
        width: stageRect.width * stageView.zoom
        height: stageRect.height * stageView.zoom

        Rectangle {
            id: stageRect
            x: 0
            y: 0
            width: stageView.contentSized ? stageView.content.implicitWidth : 240
            height: stageView.contentSized ? stageView.content.implicitHeight : 120
            color: stageView.stageColor
            radius: stageView.stageRadius
            border.color: stageView.stageBorder
            border.width: 1
            clip: stageView.clipContent

            // Top-left origin so the magnified stage occupies exactly
            // [0, w*zoom] x [0, h*zoom] inside the wrapper.
            scale: stageView.zoom
            transformOrigin: Item.TopLeft

            Behavior on width {
                NumberAnimation {
                    duration: stageView.resizeMs
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on height {
                NumberAnimation {
                    duration: stageView.resizeMs
                    easing.type: Easing.OutCubic
                }
            }

            Label {
                visible: !stageView.contentSized
                anchors.centerIn: parent
                width: parent.width - 24
                text: stageView.content ? "content has no implicitWidth / implicitHeight" : "no content"
                color: "#D20F39"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // The mouse's side buttons, as the shell's window hears them (the pointer goes with the mouse here).
    SideSwipe {
    }

    // THE HOLD, as the engine keeps it (GooeyEngine.gestureLayer). While the
    // content says a gesture is live, a wheel that lands OUTSIDE the clipped
    // stage is handed to its gestureWheel(); one inside goes through to the
    // content's own readers. Above the stage in the content's own frame, so a
    // zoomed or panned stage maps the same way.
    WheelArea {
        id: handOver
        objectName: "stageHandOver"
        // `var`: the contract's members are the content's own, not Item's.
        readonly property var live: stageView.content
        width: stageView.contentWidth
        height: stageView.contentHeight
        enabled: stageView.clipContent && !!handOver.live && handOver.live.swipeGestureActive === true
            && typeof handOver.live.gestureWheel === "function"
        turned: wheel => {
            const b = handOver.mapToItem(stageRect, wheel.x, wheel.y);
            if (b.x >= 0 && b.y >= 0 && b.x < stageRect.width && b.y < stageRect.height) {
                wheel.accepted = false;
                return;
            }
            const p = handOver.mapToItem(handOver.live, wheel.x, wheel.y);
            handOver.live.gestureWheel(Object.assign({}, wheel, { x: p.x, y: p.y }));
            wheel.accepted = true;
        }
    }
}
