import QtQuick

// =============================================================================
// LlmDismissLayer.qml -- the click-away layer of a floating menu, which does not eat the click.
//
// A menu in this module (the model list, the allowances, the pdf settings) lives in the host's overlay and is put away by a click anywhere
// else. A full-bleed MouseArea one z under the menu would do that, but a MouseArea ACCEPTS the press: the click that closed the menu would
// go to nobody else, and reaching for the tools button with the model list open would take two clicks, the first only closing the list.
// A PointHandler only WATCHES the point: the press is heard here and goes on to whatever is under it, so the same click closes the menu
// AND presses the button. (MEASURED, Qt 6.12: a TapHandler in this place takes the press as well -- the button under it never sees it --
// so the layer closes on the PRESS, as a menu does anywhere.)
//
// Declare it in the overlay: `parent: <the overlay>`, `anchors.fill: parent` (or an explicit rect), `open:` the menu's own flag.
// `dismissed(scenePoint)` says where, so a menu can leave a click on its own opener to the opener (the model pill toggles itself).
// z 299, one under the menus' own 300.
// =============================================================================
Item {
    id: root

    property bool open: false
    property int  acceptedButtons: Qt.LeftButton

    signal dismissed(point scenePoint)

    visible: root.open
    z: 299

    PointHandler {
        acceptedButtons: root.acceptedButtons
        onActiveChanged: if (active) root.dismissed(point.scenePosition)
    }
}
