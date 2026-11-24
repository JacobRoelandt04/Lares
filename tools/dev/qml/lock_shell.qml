pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "modules/bar/gooey"
import "modules/common/locale"
import "modules/common/theme"
import "modules/lockscreen"
import "modules/weather/data"
import "modules/wiki/data"
import "modules/common/system"

// =============================================================================
// tools/dev/qml/lock_shell.qml -- a stand-in for the user's shell inside the lock test
// environment (tools/dev/lock_env.sh): what the REAL shell's bar layers will do
// while the session is locked, and nothing else.
//
// Per screen one layer surface in the `lares-bar` namespace (the environment's
// Hyprland draws it above the lock surface: `above_lock`), a GooeyEngine with
// one top bar, and one LockOwner (modules/lockscreen/LockOwner.qml) listening
// on the lock's socket and hanging LockPopup from the bar's centre while a lock
// is up. The services are the mockups' own -- the weather and wiki fixtures, fake
// updates, a fake mpd -- and the real battery, read from sysfs (read-only); nothing
// touches the network.
//
//   tools/dev/lock_env.sh up
//   tools/dev/lock_env.sh run quickshell -p <a copy of the tree, this file at its root>/lock_shell.qml
//   python3 tools/dev/lock_env/probes/b_fake_lock.py ...      (the lock, faked)
//   tools/dev/lock_env.sh shot out.png
//
// Run it from a scratch copy of the tree (tools/dev/sandbox.sh's pattern): a
// quickshell rewrites `.qmlls.ini` where it starts. It never locks anything.
// While `owner.locked` the surface takes no input at all (an empty mask) and
// never the keyboard -- what the real assembly must do.
// =============================================================================
ShellRoot {
    id: root

    settings.watchFiles: false

    LocaleConfig {
        id: localeConfig
    }
    BatteryData {
        id: batteryData
    }
    WeatherMock {
        id: weatherMock
    }
    WikiMock {
        id: wiki
        scenario: "normal"
    }
    QtObject {
        id: updatesStub
        property int totalCount: 214
        property var categories: [
            { key: "core", count: 9 },
            { key: "extra", count: 180 },
            { key: "multilib", count: 14 },
            { key: "aur", count: 6 },
            { key: "flatpak", count: 5 }
        ]
    }
    QtObject {
        id: mpdStub
        property bool playing: (Quickshell.env("MPD") || "0") === "1"
        property var current: ({ title: "Sandstorm", artist: "Darude", album: "Before the Storm", file: "" })
        function coverUrlFor(file) {
            return "";
        }
    }

    LockOwner {
        id: owner
        battery: batteryData
        weather: weatherMock
        updates: updatesStub
        mpd: mpdStub
        wikiService: wiki
        locale: localeConfig
    }

    Region {
        id: noInput
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property var modelData
            screen: modelData
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "lares-bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            anchors {
                left: true
                right: true
                top: true
                bottom: true
            }
            color: "transparent"
            surfaceFormat.opaque: false
            mask: owner.locked ? noInput : gooeyMask

            GooeyMask {
                id: gooeyMask
                engine: gooeyEngine
            }

            GooeyEngine {
                id: gooeyEngine
                anchors.fill: parent
                thickness: 40
                maxR: 20
                barsList: [topBar]

                GooeyBar {
                    id: topBar
                    engine: gooeyEngine
                    barId: "top"
                    edge: "top"
                    rawPos: 0
                    rawLen: gooeyEngine.w

                    Text {
                        x: 16
                        y: Math.round((topBar.height - height) / 2)
                        text: "stand-in bar " + win.modelData.name
                        color: Theme.textMuted
                        font.family: "Audiowide"
                        font.pixelSize: 13
                    }
                    Item {
                        id: anchor
                        x: Math.round(topBar.width / 2)
                        y: 0
                        width: 1
                        height: topBar.height
                    }
                }
            }

            Component.onCompleted: owner.register(win.modelData.name, gooeyEngine, topBar, "top", anchor)
            Component.onDestruction: owner.unregister(win.modelData.name)
        }
    }
}
