pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// PipewireMock.qml -- PipewireService with no sound server behind it.
//
// The members a consumer reads (the volume placeholder, the OSD's audio source): `ready`,
// `defaultSink` / `defaultSource` as nodes with `audio.volume` / `audio.muted`, and the
// write helpers, which change the plain numbers here and nothing else. The shell's mock mode
// (SHELL_SERVICES=mock: mockups/shell.qml, every probe) uses it, so nothing in a test can move the
// desktop's volume or mute its microphone.
// =============================================================================
Item {
    id: root

    readonly property bool ready: true
    readonly property var defaultSink: sink
    readonly property var defaultSource: source
    readonly property var nodes: [sink, source]

    property var trackedAudioNodes: [sink, source]
    property var hardwareSinks: [sink]
    property var hardwareSources: [source]
    property var outputStreams: []
    property var inputStreams: []

    // The audio popup's read-back asks these of any backend.
    property bool linksWanted: false
    property var linkPairs: []
    function linkTargetOf(mediaName: string): string { return ""; }

    // What the writes did, for a probe: [{ what, node, value }], oldest first.
    property var writes: []

    component AudioState: QtObject {
        property real volume: 0.5
        property bool muted: false
    }
    component Node: QtObject {
        id: node
        property string name: ""
        property string description: ""
        property bool isSink: false
        property bool isStream: false
        property var properties: ({})
        property real startVolume: 0.5
        property AudioState audio: AudioState {
            volume: node.startVolume
        }
    }
    Node {
        id: sink
        name: "mock-sink"
        description: "Mock speakers"
        isSink: true
    }
    Node {
        id: source
        name: "mock-source"
        description: "Mock microphone"
        startVolume: 0.6
    }

    function _note(what: string, node: var, value: var): void {
        root.writes = root.writes.concat([{ what: what, node: node ? node.name : "", value: value }]);
    }

    function appBinary(node: var): string { return ""; }
    function appName(node: var): string { return ""; }
    function appIconName(node: var): string { return ""; }
    function mediaTitle(node: var): string { return ""; }
    function appIdentity(node: var): string { return node ? node.name : ""; }

    function setVolume(node: var, v: real): void {
        if (node && node.audio) {
            node.audio.volume = Math.max(0, v);
            root._note("volume", node, node.audio.volume);
        }
    }
    function setMuted(node: var, m: bool): void {
        if (node && node.audio) {
            node.audio.muted = m;
            root._note("muted", node, m);
        }
    }
    function setVolumes(node: var, volumes: var): void {
        if (node && node.audio) {
            let s = 0;
            for (let i = 0; i < volumes.length; i++)
                s += volumes[i];
            node.audio.volume = volumes.length > 0 ? s / volumes.length : 0;
            root._note("volume", node, node.audio.volume);
        }
    }
    function bumpVolume(node: var, delta: real): void {
        if (node && node.audio) {
            node.audio.volume = Math.max(0, Math.min(1.5, node.audio.volume + delta));
            root._note("volume", node, node.audio.volume);
        }
    }
    function toggleMute(node: var): void {
        if (node && node.audio) {
            node.audio.muted = !node.audio.muted;
            root._note("muted", node, node.audio.muted);
        }
    }
    function setDefaultSink(node: var): void {}
    function setDefaultSource(node: var): void {}
}
