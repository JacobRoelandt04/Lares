import QtQuick

// a shared component that holds another shared component behind an alias
Item {
    id: root
    readonly property alias inner: boxInside
    SharedBox {
        id: boxInside
    }
}
