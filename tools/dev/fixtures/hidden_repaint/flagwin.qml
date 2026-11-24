// A window that turns from white to black when the flag file appears (a stand-in for a Qt app taking a theme).
import QtQuick
Window {
    id: w
    visible: true; width: 600; height: 400; color: "white"
    title: Qt.application.arguments[Qt.application.arguments.length - 2]
    readonly property string flag: Qt.application.arguments[Qt.application.arguments.length - 1]
    Timer {
        interval: 60; repeat: true; running: w.color != "#000000"
        onTriggered: {
            const x = new XMLHttpRequest();
            x.onreadystatechange = () => { if (x.readyState === XMLHttpRequest.DONE && x.responseText.length > 0) w.color = "black"; };
            x.open("GET", "file://" + w.flag); x.send();
        }
    }
}
