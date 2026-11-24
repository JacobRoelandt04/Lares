import QtQuick

// =============================================================================
// PanelPage.qml -- one page of a PanelFrame: a column of cards and blocks, shown while `shown` is true. A page that is not shown
// takes no height (the frame sizes the panel to the page on show, and the engine eases the resize). `pageId` names it for the tabs.
// =============================================================================
Column {
    id: page

    property string pageId: ""
    property bool shown: false
    property PanelStyle look: null

    width: parent ? parent.width : 0
    spacing: page.look ? page.look.gap : 12
    visible: page.shown
}
