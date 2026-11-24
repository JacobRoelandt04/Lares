import QtQuick
import "../common/components"

// a third module's content, with a one-line object and an empty one to write into
Item {
    id: popup
    property real pad: 12
    property real gapOne: 3
    property string fontFamily: "Inter"
    SharedBox { id: tight }
    SharedBox {}
}
