import QtQuick

// =============================================================================
// DeviceScale.qml -- how many DEVICE pixels one pixel of the item it sits in is drawn as.
//
//     DeviceScale { id: dev }
//     layer.textureSize: dev.texSize(width, height)   // a texture made at the glass's resolution
//     sourceSize: dev.size(w, h)                      // a decode at the size it is shown
//     ... n * dev.value ...
//
// WHY. The shell is laid out in DESIGN pixels and drawn magnified (ShellScreen puts the whole frame in a ScaleRoot, so a
// design px is `configured` device px whatever Hyprland's own scale is). A texture, a decode or a canvas
// made at the DESIGN size is then stretched and goes soft; made at `value` x its size it is the glass's own. Text, the
// SDF shaders (ShadowBox, Chevron ...) and Shapes need nothing: they draw per device pixel.
//
// A component deep in a popup cannot be handed the number by every host above it, and a host that forgot would leave a soft
// picture nobody sees until the user does. So the number is found, not passed:
//   - the NEAREST ScaleRoot above (its `deviceScale`: the window's ratio x every root's factor on the way), else
//   - the window's own devicePixelRatio, else 1.
// An `Item.scale` that is not a ScaleRoot -- a row that bobs, a card that is lifted, a page that is morphed -- is NOT
// followed: it is a transient magnification of a picture, not the screen's scale, and a texture that re-made itself on every
// frame of it would cost more than it gave.
//
// `from` is where the search starts (default: the item this sits in). A ScaleRoot asks from ITS parent, never through itself.
// =============================================================================
Item {
    id: root

    visible: false
    width: 0
    height: 0

    // The item whose pixels are counted.
    property Item from: root.parent

    // Device px per px of `from`.
    readonly property real value: root._find(root.from)

    function _find(start: var): real {
        for (let p = start; p; p = p.parent)
            if (p.deviceScale !== undefined)
                return p.deviceScale;
        const w = root.Window.window;
        return w && w.devicePixelRatio > 0 ? w.devicePixelRatio : 1;
    }

    // A size of `w` x `h` design px in whole device px, never under one: what a decode's sourceSize takes.
    // (1e-3: a product like 384 * 0.8 + 0.8 is 308.00000000000006 and must not cost a column.)
    function size(w: real, h: real): size {
        const s = root.value;
        return Qt.size(Math.max(1, Math.ceil(w * s - 1e-3)), Math.max(1, Math.ceil(h * s - 1e-3)));
    }

    // The textureSize of a layer or a ShaderEffectSource: the size() above where the picture is magnified, and Qt's OWN default
    // (0 x 0: the item's size x the window's pixel ratio) where it is not. A requested size, even one equal to the default, is not
    // the default path: the lifted shadow of a RowFlight comes out up to 3 levels off over 5 000 px, and the notifications' clone
    // lands 60 levels off the card it lands on. Where nothing is magnified the shell must draw what Qt's own default draws.
    function texSize(w: real, h: real): size {
        const win = root.Window.window;
        const own = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1;
        return Math.abs(root.value - own) < 1e-6 ? Qt.size(0, 0) : root.size(w, h);
    }
}
