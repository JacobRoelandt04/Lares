pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// OsdIpc.qml -- `quickshell ipc call osd <fn> [args]`, for scripts. The hardware
// keys do not come through here (a process per repeat at 25 Hz would be absurd:
// OsdShortcuts); this is what a script, a keybind of somebody else's, or a
// recording tool calls. CONTRACT section 11.
//
//   volume <up|down|mute>      mic <up|down|mute>
//   brightness <up|down|up-fine|down-fine>     kbd <up|down>
//   lockkeys                   media <next|prev|toggle|stop>
//   capture <shot|rec|copied|deleted> <a> <b>
//       shot <path> <copied|plain>    rec <start|stop> <path>    copied <label> ""    deleted <path> ""
//       (deleted is no card: the owner takes down the shot's card, its notification leaves -- tools/notifications/shot_trash.sh)
//       (IpcHandler has no optional arguments: pass "" for the one a call lacks)
//   request <json>             a CONTRACT section 1 request, source "ipc". (Not `show`:
//                              that is a subcommand of `quickshell ipc` itself, which
//                              swallows it before the handler is asked.)
//   dismiss                    the owner closes whatever is shown
//   test <kind>                a plausible request of that kind
//
// Every function answers "true" when it did something, "false" when it did not
// (no such kind, a route that is off, a value with no device behind it, bad JSON).
// =============================================================================
Scope {
    id: root

    property var service: null

    function _request(json) {
        if (!root.service)
            return false;
        let req = null;
        try {
            req = JSON.parse(json);
        } catch (e) {
            return false;
        }
        if (req === null || typeof req !== "object" || Array.isArray(req))
            return false;
        if (req.source === undefined)
            req.source = "ipc";
        return root.service.show(req) === true;
    }

    IpcHandler {
        target: "osd"

        function volume(verb: string): bool {
            return root.service ? root.service.volume(verb) === true : false;
        }
        function mic(verb: string): bool {
            return root.service ? root.service.mic(verb) === true : false;
        }
        function brightness(verb: string): bool {
            return root.service ? root.service.brightness(verb) === true : false;
        }
        function kbd(verb: string): bool {
            return root.service ? root.service.kbd(verb) === true : false;
        }
        function lockkeys(): bool {
            return root.service ? root.service.lockkeys() === true : false;
        }
        function media(verb: string): bool {
            return root.service ? root.service.media(verb) === true : false;
        }
        function capture(what: string, a: string, b: string): bool {
            return root.service ? root.service.capture(what, a, b) === true : false;
        }
        function request(json: string): bool {
            return root._request(json);
        }
        function dismiss(): void {
            if (root.service)
                root.service.dismiss();
        }
        function test(kind: string): bool {
            return root.service ? root.service.test(kind) === true : false;
        }
    }
}
