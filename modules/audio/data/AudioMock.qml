pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AudioMock.qml -- AudioService on AudioWorld: everything the real one does, deadlines and read-back included, against a sound system that does not exist. The shell's mock
// mode and the mockup use it. `world` is there for a scenario to break.
// =============================================================================
AudioService {
    id: root

    property bool rich: true
    readonly property alias world: theWorld
    live: false
    pipewire: theWorld
    machine: theWorld

    AudioWorld {
        id: theWorld
        rich: root.rich
        onChanged: root.poke()
    }
    Component.onCompleted: theWorld.ensureBuilt()
}
