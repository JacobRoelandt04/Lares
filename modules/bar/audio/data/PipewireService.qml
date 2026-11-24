pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

// =============================================================================
// PipewireService.qml
//
// Wraps Quickshell.Services.Pipewire for the audio module. Surface:
//   • Aliases for default sink / source (read) + their writable preferred
//     counterparts (set via setDefault* helpers).
//   • Pre-categorised live lists of audio nodes:
//       - hardwareSinks      (devices that play audio)
//       - hardwareSources    (devices that record audio)
//       - outputStreams      (apps producing audio → sink)
//       - inputStreams       (apps consuming audio ← source)
//   • A PwObjectTracker auto-bound to every known audio node so its
//     volume / muted / properties become valid without per-call binding.
//   • App-identity helpers (binary, name, icon-name, media title, stable
//     identity key) that the management view + persistence layer
//     reuse.
//   • Volume / mute write helpers with light clamping (0..1.5 to allow
//     the GrooveSlider boost cap).
//
// Internal: the categorised lists are rebuilt when the node list changes. `Pipewire.nodes` is an ObjectModel: standard QML bindings don't
// recompute on its content, but it says `valuesChanged`, so the lists follow that signal and nothing polls (a poll would be the most
// frequent wakeup of a shell at rest: SPIKES.md).
// =============================================================================
Item {
    id: root

    // ---- Pass-throughs ----
    readonly property bool ready: Pipewire.ready
    readonly property var defaultSink:   Pipewire.defaultAudioSink
    readonly property var defaultSource: Pipewire.defaultAudioSource
    readonly property var nodes:         Pipewire.nodes

    // ---- Live categorised lists (refreshed by _rebuild) ----
    property var trackedAudioNodes: []
    property var hardwareSinks:     []
    property var hardwareSources:   []
    property var outputStreams:     []
    property var inputStreams:      []

    // ---- The link graph (the audio popup's patch lines, its read-back): only while somebody holds it ----
    // `linksWanted` is host-written (AudioService, while its popup is open). [{ source, target }] node ids, one per
    // link GROUP: what really goes where. While wanted, the node and link models say at once when they change,
    // without the 60 ms settle a burst of nodes waits for, so a moved stream's line follows at once.
    property bool linksWanted: false
    property var linkPairs: []
    function _rebuildLinks() {
        const out = [];
        if (root.linksWanted) {
            const a = Pipewire.linkGroups ? Pipewire.linkGroups.values : [];
            for (let i = 0; i < a.length; i++) {
                const g = a[i];
                if (g && g.source && g.target)
                    out.push({ source: g.source.id, target: g.target.id });
            }
        }
        if (JSON.stringify(out) !== JSON.stringify(root.linkPairs))
            root.linkPairs = out;
    }
    onLinksWantedChanged: {
        root._rebuildLinks();
        if (root.linksWanted)
            root._rebuild();
    }
    Connections {
        target: root.linksWanted ? Pipewire.linkGroups : null
        function onValuesChanged() {
            root._rebuildLinks();
        }
    }
    Connections {
        target: root.linksWanted ? Pipewire.nodes : null
        function onValuesChanged() {
            root._rebuild();
        }
    }
    // The name of the device the node with this `media.name` is linked to, "" when it has no link (the test tone's read-back).
    function linkTargetOf(mediaName) {
        const a = root.trackedAudioNodes;
        for (let i = 0; i < a.length; i++) {
            if (a[i] && a[i].properties && a[i].properties["media.name"] === mediaName) {
                for (let j = 0; j < root.linkPairs.length; j++)
                    if (root.linkPairs[j].source === a[i].id) {
                        const t = root.linkPairs[j].target;
                        for (let k = 0; k < a.length; k++)
                            if (a[k] && a[k].id === t)
                                return a[k].name;
                    }
                return "";
            }
        }
        return "";
    }

    // ---- Tracker: binds every audio node so its properties / audio block
    //      are valid. Updated whenever trackedAudioNodes changes. ----
    PwObjectTracker {
        id: tracker
        objects: root.trackedAudioNodes
    }

    function _rebuild() {
        const m = Pipewire.nodes;
        const all = [], hs = [], hsr = [], os = [], is = [];
        if (m) {
            const arr = m.values || [];
            for (let i = 0; i < arr.length; i++) {
                const n = arr[i];
                if (!n || !n.audio) continue;
                all.push(n);
                if (n.isStream) {
                    if (n.isSink) is.push(n);
                    else          os.push(n);
                } else {
                    if (n.isSink) hs.push(n);
                    else          hsr.push(n);
                }
            }
        }
        // Only assign if the contents actually changed — avoids spurious
        // tracker rebinds + Repeater delegate churn on every rebuild.
        // Compare by node.id rather than object identity: Quickshell may
        // hand out fresh wrappers per `Pipewire.nodes.values` access while
        // the underlying ids stay stable, and a ref-only check would fail
        // every rebuild, blowing every delegate (and any Process held inside).
        if (!_sameByIds(trackedAudioNodes, all)) trackedAudioNodes = all;
        if (!_sameByIds(hardwareSinks,     hs))  hardwareSinks     = hs;
        if (!_sameByIds(hardwareSources,   hsr)) hardwareSources   = hsr;
        if (!_sameByIds(outputStreams,     os))  outputStreams     = os;
        if (!_sameByIds(inputStreams,      is))  inputStreams      = is;
    }

    function _sameByIds(a, b) {
        if (a === b) return true;
        if (!a || !b) return false;
        if (a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            const ai = a[i], bi = b[i];
            if (!ai || !bi) return false;
            if (ai.id !== bi.id) return false;
        }
        return true;
    }

    Component.onCompleted: _rebuild()
    onReadyChanged: _rebuild()
    Connections {
        target: Pipewire.nodes
        function onValuesChanged() {
            nodesSettle.restart();
        }
    }
    // One rebuild for a burst: an app or a card brings several nodes at once.
    Timer {
        id: nodesSettle
        interval: 60
        onTriggered: root._rebuild()
    }

    // ---- App-identity helpers (used by management view + persistence) ----
    function _prop(node, key) {
        return (node && node.properties) ? (node.properties[key] || "") : "";
    }
    function appBinary(node)   { return _prop(node, "application.process.binary"); }
    function appName(node)     { return _prop(node, "application.name"); }
    function appIconName(node) { return _prop(node, "application.icon-name"); }
    function mediaTitle(node) {
        return _prop(node, "media.title") || _prop(node, "media.name");
    }
    // Stable identity key — binary first (most reliable across launches),
    // fall back to application.name then node.name.
    function appIdentity(node) {
        return appBinary(node)
            || appName(node)
            || (node ? node.name : "");
    }

    // ---- Volume / mute write helpers ----
    function setVolume(node, v) {
        if (node && node.audio) node.audio.volume = Math.max(0, v);
    }
    function setMuted(node, m) {
        if (node && node.audio) node.audio.muted = m;
    }
    // Per channel, in the node's own channel order (the audio popup's unlocked sliders).
    function setVolumes(node, volumes) {
        if (node && node.audio) node.audio.volumes = volumes;
    }
    function bumpVolume(node, delta) {
        if (!node || !node.audio) return;
        node.audio.volume = Math.max(0, Math.min(1.5, node.audio.volume + delta));
    }
    function toggleMute(node) {
        if (node && node.audio) node.audio.muted = !node.audio.muted;
    }

    // ---- Default device write helpers (hint Pipewire) ----
    function setDefaultSink(node)   { Pipewire.preferredDefaultAudioSink   = node; }
    function setDefaultSource(node) { Pipewire.preferredDefaultAudioSource = node; }
}
