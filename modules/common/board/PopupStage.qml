pragma ComponentBehavior: Bound

import QtQuick

import "../components"

// =============================================================================
// PopupStage.qml -- a popup content that is drawn larger or smaller than the shell's popup standard by a number of its OWN
// (a popup that is mostly a picture drawn per pixel by shaders: silicon's board, aerial's).
//
//     PopupStage {                            // SiliconPopup.qml's root
//         sizeScale: 1.2                      // the owner's `sizeScale`, handed down (SiliconBarOwner)
//         designWidth: 760                    // what it asks for at scale 1, in the units its children are laid out in
//         designHeight: board.naturalHeight
//         BoardScene { width: 760; ... }      // every child declared in the deriving file lands in the stage, in DESIGN px
//     }
//
// WHY NOT THE SHELL'S POPUP RATIO. `scale.popup` (shell.jsonc) is the one number of the SIZE STANDARD: every popup at once, text and lists
// together, tuned for reading. A popup that is mostly a picture drawn per pixel by shaders has no reading size, so it is the
// exception: its own number, on top of the standard, free. The engine's body already hosts a content in a ScaleRoot of the popup ratio
// (GooeyEngine: THE RATIOS); this is a second ScaleRoot inside it, so a design pixel is `ratio x sizeScale` frame pixels and every
// DeviceScale consumer below (and the `renderScale` the deriving popup multiplies by `stageScale`) finds the product.
//
// WHAT THE ENGINE SEES. The root is in the engine's CONTENT units (the engine multiplies them by the body's ratio): its implicit size is
// the design size x `sizeScale`, and every number the deriving popup tells the engine in item px (a popup's `secondaryAnchor`; its `secondaryInset`
// is 0, which is 0 in any unit) is multiplied by `stageScale` where it is declared, and every one the engine hands back in content units (a
// gesture wheel's x / y) is divided by it. Everything else -- the pointer, hover, wheel and keys inside -- maps through the transform on
// its own. At `sizeScale` 1 the stage is an identity (no transform node, the same size): the popup is drawn at the standard.
//
// THE STAGE IS AS BIG AS THE BOX, NOT AS THE ASK. While the popup opens the box is smaller than the content asked for; `stageWidth` is
// the box's width in design px, and a child laid out at the asked size (the board is) simply reaches past it and is clipped by
// the body, as every popup's content is.
// =============================================================================
Item {
    id: root

    // ---- in ----
    // Design px per content px. A value that is not a positive number is 1.
    property real sizeScale: 1
    // The size the content asks for at scale 1, in design px.
    property real designWidth: 0
    property real designHeight: 0

    // ---- out ----
    // `sizeScale` as it is used.
    readonly property real stageScale: root.sizeScale > 0.01 ? root.sizeScale : 1
    // The box, in design px.
    readonly property real stageWidth: stage.width

    implicitWidth: root.designWidth * root.stageScale
    implicitHeight: root.designHeight * root.stageScale

    // Every child the deriving file declares is the stage's. (The stage itself is this file's own child: a default property is applied to the children
    // of whoever instantiates the type, not to the ones declared beside it.)
    default property alias content: stage.data

    ScaleRoot {
        id: stage
        factor: root.stageScale
        hostWidth: root.width
        hostHeight: root.height
    }
}
