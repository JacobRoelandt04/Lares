import QtQuick

// A FINISHED nested component: its helpers are no longer pinned on the JS stack once it is built.
Item {
    Helper {}
    Helper {}
    Helper {}
    Helper {}
    Timer { property int extra: 1 }
}
