import QtQuick

// =============================================================================
// AirplayWatchMock.qml -- AirplayWatch with no sound server, no radio and no helper behind it (SHELL_SERVICES=mock: mockups/shell.qml,
// every probe). The same surface; the facts are plain properties a probe writes, and nothing is ever run. `delayMs` follows them the
// way the live one does (the sink's latency while mpd goes into it).
// =============================================================================
Item {
    id: root

    property bool live: false
    property string configPath: ""
    property string stateFile: ""

    property bool sending: false
    property bool mpdInto: false
    property string sinkName: ""
    property int latencyMs: 0
    property int delayExtraMs: 0
    readonly property int delayMs: root.mpdInto ? Math.max(0, root.latencyMs + root.delayExtraMs) : 0

    property string iface: ""
    property string powerSave: ""
    property bool ours: false
    property string helperState: "unknown"
    property int reasserts: 0
    property var jobLog: []
    property var config: ({ powersave: true, graceSec: 60, delay: "auto", delayExtraMs: 0 })
    function applyConfig(obj: var): void {}
}
