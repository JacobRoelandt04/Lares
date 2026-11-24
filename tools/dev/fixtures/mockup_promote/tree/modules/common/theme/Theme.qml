pragma Singleton
import QtQuick

// fixture: only what the promotion reads -- the two maps and the tokens' properties
QtObject {
    id: root
    property var defaults: ({
        "accent": "#4480F4",
        "error": "#EC0000",
        "surface": "#EAEDF5",
        "textPrimary": "#5D5D5F"
    })
    property var aliases: ({
        "warnStrong": "error",
        "primary": "textPrimary"
    })
    readonly property color accent: "#4480F4"
    readonly property color error: "#EC0000"
    readonly property color surface: "#EAEDF5"
    readonly property color textPrimary: "#5D5D5F"
}
