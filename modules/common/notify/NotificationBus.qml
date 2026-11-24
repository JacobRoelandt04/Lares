pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// NotificationBus.qml -- where the shell's ONE NotificationService is found.
//
// Emitters outside the notification module (DesktopNotifier,
// LlmAttention) look here: with `service` set they post in process, without
// it they use their notify-send path. Only a
// NotificationService writes it (its `registerOnBus`), and it clears it
// again when it goes away, so a stale pointer is never left behind.
// =============================================================================
Singleton {
    property var service: null
}
