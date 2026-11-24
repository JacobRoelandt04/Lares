import QtQuick

// The delegate's root with THE CURE (modules/shell/ShellScreen.qml): the cycle in flight is finished while this root has no parent yet.
Item {
    Sub {}
    Component.onCompleted: gc()
}
