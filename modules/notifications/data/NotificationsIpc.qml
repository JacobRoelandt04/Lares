pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// NotificationsIpc.qml -- `quickshell ipc call notifications <fn> [args]`.
//
//   dnd on|off|toggle|""   -> "on" | "off" (the state after; "" only asks)
//   open / toggle / close  the manager, on the focused screen
//   count                  unseen notifications
//   hold <reason> <bool>   locked | screencast | fullscreen | idle
//
// The lock hold is the one the user wires: hypridle's
//   lock_cmd = quickshell ipc call notifications hold locked true; pidof hyprlock || hyprlock
//   unlock_cmd / after hyprlock exits: quickshell ipc call notifications hold locked false
// (no lock signal can be read without locking the session).
// =============================================================================
Scope {
    id: root

    property var service: null

    IpcHandler {
        target: "notifications"

        function dnd(mode: string): string {
            const s = root.service;
            if (!s)
                return "";
            if (mode === "on")
                s.dnd = true;
            else if (mode === "off")
                s.dnd = false;
            else if (mode === "toggle")
                s.dnd = !s.dnd;
            return s.dnd ? "on" : "off";
        }

        function open(): void {
            if (root.service)
                root.service.openManagerRequested(root.service.holds.focusedScreen);
        }

        function toggle(): void {
            if (!root.service)
                return;
            if (root.service.managerOpen)
                root.service.closeManagerRequested();
            else
                root.service.openManagerRequested(root.service.holds.focusedScreen);
        }

        function close(): void {
            if (root.service)
                root.service.closeManagerRequested();
        }

        function count(): int {
            return root.service ? root.service.unseenCount : 0;
        }

        function hold(reason: string, on: bool): void {
            const h = root.service ? root.service.holds : null;
            if (!h)
                return;
            if (reason === "locked" || reason === "screencast" || reason === "fullscreen" || reason === "idle")
                h[reason] = on;
        }
    }
}
