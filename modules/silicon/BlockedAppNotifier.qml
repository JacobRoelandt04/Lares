pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "data/SiliconModel.js" as Model
import "popup/MuxFlow.js" as Flow

// =============================================================================
// BlockedAppNotifier.qml -- Smart mode kept an app off the dGPU (CONTRACT section 11).
// The owner holds one; it has no visual.
//
// On `vm.appBlocked(app)` (`{id, comm, appId, pid, gpuId, atMs}`) ONE desktop notification per app per
// session:
//
//   Zen Browser stayed on the integrated GPU
//   Smart mode only lets the apps you allow use the NVIDIA card.            [ Allow always ] [ Ignore ]
//
//   Allow always  -> vm.setAppPolicy(id, true)
//   Ignore        -> vm.ignoreApp(id): never asked again (the data layer persists it)
//
// NOT NOTIFIED: an app in `vm.gpu.ignoredApps` (or whose policy row says `ignored`) -- the data layer drops
// those before the signal, and this asks again, so an ignored app is never shown whichever side is stale;
// a repeat of an app already notified this session; and anything while the GPU is not in Smart (Integrated
// blocks every app on purpose: "Allow always" would change nothing there, and every app would ask).
//
// The notifier posts through DesktopNotifier (notify-send today, the shell's own notification service when
// one is up). Its pool of waiters is one per key, so the keys are four slots handed out in turn: four apps
// can have a notification open at once, a fifth takes the oldest one's place.
// =============================================================================
Item {
    id: root

    property var vm: null

    visible: false

    readonly property var _keys: ["silicon-app-0", "silicon-app-1", "silicon-app-2", "silicon-app-3"]
    // plain bookkeeping that no binding reads: mutated in place
    property var _seen: ({})
    property var _slotApp: ["", "", "", ""]
    property int _next: 0

    function _gpu() {
        return root.vm ? root.vm.gpu : null;
    }

    function _ignored(id) {
        const g = root._gpu();
        const list = g && Array.isArray(g.ignoredApps) ? g.ignoredApps : [];
        if (list.indexOf(id) >= 0)
            return true;
        const rows = g && Array.isArray(g.policies) ? g.policies : [];
        for (let i = 0; i < rows.length; i++) {
            if (rows[i] && rows[i].id === id && rows[i].ignored === true)
                return true;
        }
        return false;
    }

    function _onBlocked(app) {
        const id = Flow.appId(app);
        const g = root._gpu();
        if (id === "" || !g || g.step !== Model.STEP.SMART || (root.vm.config && root.vm.config.gpu.blockedNotice === false))
            return;
        if (root._seen[id] === true || root._ignored(id))
            return;
        root._seen[id] = true;
        const slot = root._next;
        root._next = (root._next + 1) % root._keys.length;
        root._slotApp[slot] = id;
        const c = Flow.blockedCopy(Flow.appName(app, g.policies));
        notifier.notify(root._keys[slot], { title: c.title, body: c.body, actions: c.actions, timeoutMs: 12000 });
    }

    function _answered(key, answer) {
        const slot = root._keys.indexOf(key);
        if (slot < 0 || !root.vm)
            return;
        const id = root._slotApp[slot];
        if (id === "")
            return;
        root._slotApp[slot] = "";
        if (answer === "allow")
            root.vm.setAppPolicy(id, true);
        else if (answer === "ignore")
            root.vm.ignoreApp(id);
    }

    Connections {
        target: root.vm
        ignoreUnknownSignals: true
        function onAppBlocked(app: var) {
            root._onBlocked(app);
        }
    }

    DesktopNotifier {
        id: notifier
        appName: "Silicon"
        keys: root._keys
        onAction: (key, id) => root._answered(key, id)
    }
}
