pragma Singleton
import QtQuick

// a singleton feel: the shell-wide default IS its declaration
QtObject {
    property real speed: 1.0
    property int notchMs: 140
}
