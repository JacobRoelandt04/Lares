import QtQuick
import "../common/components"

// a second module: it is what makes SharedBox, SharedStyle, BaseShape and SharedHolder shared
Item {
    id: popup
    property SharedStyle style: SharedStyle {}
    SharedBox {
        id: box
    }
    SharedHolder {
        id: holder
    }
    BaseShape {
        id: shape
    }
}
