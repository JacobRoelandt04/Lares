pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/scroll"

// =============================================================================
// PanelFrame.qml -- the frame every aerial panel stands in, so no panel carries a layout of its own: the title (16 bold) and its
// line of words, the page tabs (when there are two or more), and the page, scrolled by the shell's ScrollDressing when it is taller
// than `look.maxHeight` allows. Everything is 12 px from the edge; the popup's surface is the ground.
//
//   title / subtitle / subtitleTone   the head
//   tabs [{ id, label }]              the pages; `page` is the one shown (the host may write it; a tab click writes it)
//   PanelPage { pageId: "x"; shown: frame.page === "x" }   children: the pages (default property)
//   overlay                            the layer for floating things (tips); above everything
//
// Its implicit size is what the panel asks of the engine: panelWidth x (head + tabs + the page, capped). The page's height is read
// from the page that is `shown`, never from the Flickable (a Flickable that follows its content's size is a loop).
// =============================================================================
Item {
    id: frame

    property PanelStyle look: PanelStyle {}
    property string title: ""
    property string subtitle: ""
    property int subtitleTone: 1
    property real maxHeight: frame.look.maxHeight
    property var tabs: []
    property string page: frame.tabs.length > 0 ? frame.tabs[0].id : ""
    default property alias pages: host.data
    readonly property alias overlay: overlayLayer
    readonly property alias scroller: scrollBox
    readonly property alias dressing: dressing

    signal pageSelected(string id)

    readonly property real _pad: frame.look.padding
    readonly property bool _tabbed: frame.tabs.length > 1
    readonly property real _tabH: 34
    readonly property real _flickTop: Math.ceil(head.y + head.implicitHeight + (frame._tabbed ? frame.look.gap + frame._tabH : 0) + frame.look.gap - 2)

    readonly property real pageHeight: {
        const n = host.children.length;
        for (let i = 0; i < n; i++) {
            const c = host.children[i];
            if (c && c.shown === true)
                return Math.ceil(c.implicitHeight);
        }
        return 0;
    }
    // the content: the page, 2 px of slack above (a carved card's bevel is drawn outside its edge) and the padding below
    readonly property real _contentH: frame.pageHeight + 2 + frame._pad
    readonly property real _roomMax: Math.max(80, frame.maxHeight - frame._flickTop)

    implicitWidth: frame.look.panelWidth
    implicitHeight: Math.ceil(frame._flickTop + Math.min(frame._contentH, frame._roomMax))

    Column {
        id: head
        x: frame._pad
        y: frame._pad
        width: frame.width - 2 * frame._pad
        spacing: 4
        PText {
            look: frame.look
            strong: true
            width: parent.width
            text: frame.title
            elide: Text.ElideRight
        }
        PText {
            look: frame.look
            tone: frame.subtitleTone
            width: parent.width
            shown: frame.subtitle !== ""
            text: frame.subtitle
            wrapMode: Text.WordWrap
        }
    }

    PanelTabs {
        id: tabsel
        objectName: "panelTabs"
        look: frame.look
        visible: frame._tabbed
        x: frame._pad
        y: head.y + head.implicitHeight + frame.look.gap
        width: frame.width - 2 * frame._pad
        height: frame._tabH
        tabs: frame.tabs
        onTabChanged: id => {
            frame.page = id;
            frame.pageSelected(id);
        }
    }
    // the tabs follow `page` (a host may move it); a plain binding would die at the first click
    Binding {
        target: tabsel
        property: "currentTab"
        value: frame.page
    }

    Flickable {
        id: scrollBox
        objectName: "panelScroll"
        y: frame._flickTop
        width: frame.width
        height: Math.max(0, frame.height - frame._flickTop)
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: frame._contentH
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: host
            x: frame._pad
            y: 2
            width: frame.width - 2 * frame._pad
            height: frame.pageHeight
        }
    }
    ScrollDressing {
        id: dressing
        anchors.fill: scrollBox
        flick: scrollBox
        ground: Theme.surface
        fadeHeight: 18
    }

    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 100
    }
}
