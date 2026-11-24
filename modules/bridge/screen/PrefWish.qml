pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// PrefWish.qml -- a device's preference as the user is asking for it, until the tool has said. The tool owns the value
// (`prefs` of the device record); a control that wrote it and then showed ITS OWN idea of the value would show a lie when the
// write did not take. So a control reads `value(name)`:
//
//   the wish  from the moment it is asked until the tool's line carries it (`prefs[name]` equals it), the tool answers that the
//             write failed (the service's `acted` for `set`), or `holdMs` has passed
//   the pref  otherwise -- which is what a write that did not take looks like: the old value, back where it was
//
// so the control answers at once and corrects itself when it was wrong.
//
//   service, deviceKey   who to ask (`service.setPref(deviceKey, name, value)`), for which device
//   prefs                the device's `prefs` object as the last line carried it
//   value(name)          what to show;   set(name, value)   ask for it
// =============================================================================
Item {
    id: wish

    property var service: null
    property string deviceKey: ""
    property var prefs: null
    property int holdMs: 2500

    visible: false

    // name -> the wished value
    property var _w: ({})

    function value(name: string): var {
        return Object.prototype.hasOwnProperty.call(wish._w, name) ? wish._w[name] : (wish.prefs ? wish.prefs[name] : undefined);
    }
    function set(name: string, v: var): void {
        if (!wish.service || wish.deviceKey === "")
            return;
        const n = Object.assign({}, wish._w);
        n[name] = v;
        wish._w = n;
        hold.restart();
        wish.service.setPref(wish.deviceKey, name, v);
    }
    function _forget(): void {
        hold.stop();
        wish._w = ({});
    }
    // the tool's line carried a wish: it is the pref now. A change that wrote nothing is not written: a reader of `value()` is
    // mid-evaluation when `prefs` is first read, and a write there is a binding loop.
    onPrefsChanged: {
        let kept = 0, total = 0;
        const left = {};
        for (const k in wish._w) {
            total++;
            if (!wish.prefs || wish.prefs[k] !== wish._w[k]) {
                left[k] = wish._w[k];
                kept++;
            }
        }
        if (total === 0 || kept === total)
            return;
        wish._w = left;
        if (kept === 0)
            hold.stop();
    }
    onDeviceKeyChanged: wish._forget()

    Connections {
        target: wish.service
        function onActed(key: string, action: string, ok: bool, why: string): void {
            if (action === "set" && key === wish.deviceKey && !ok)
                wish._forget();
        }
    }
    Timer {
        id: hold
        interval: wish.holdMs
        onTriggered: wish._w = ({})
    }
}
