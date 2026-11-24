pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// AuthBus.qml -- where the shell's ONE AuthBroker is found.
//
// Anything that has to ask the user to authenticate (polkit through the
// broker's own PolkitSource; sudo's askpass in the LLM's tool jobs and the
// system update) opens a request on `broker`. Only an AuthBroker
// writes it (`registerOnBus`), and it clears it again when it goes away.
// =============================================================================
Singleton {
    property var broker: null
}
