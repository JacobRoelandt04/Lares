pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Notifications

// =============================================================================
// NotificationServerBridge.qml -- org.freedesktop.Notifications, owned.
//
// The service creates this through a LazyLoader, so `serverEnabled: false`
// never registers the name (a probe, a second shell, the mockup's in-process
// mode). Everything past the capabilities is the service's `receive(n)`,
// which FakeNotification also goes through: tracking (never for a
// synchronous OSD hint -- an untracked notification is reported Dismissed to
// its sender within milliseconds), the change signals a replace
// arrives as, and the close.
//
// Capabilities (every *Supported is advertised as set): body,
// markup, hyperlinks, actions, image, inline reply, persistence. `extraHints`
// is APPENDED TO THE CAPABILITY LIST (it is not a hint filter -- every hint
// arrives either way), so it carries exactly one word: "sound", because
// sound-file / sound-name / suppress-sound are honoured.
// x-canonical-private-synchronous is NOT advertised: those are dropped.
// `keepOnReload`: a reload hands the live notifications to the new
// generation (`lastGeneration`), which the service relinks to their records.
// =============================================================================
Scope {
    id: root

    property var service: null
    readonly property var server: srv

    NotificationServer {
        id: srv
        bodySupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: false
        actionsSupported: true
        actionIconsSupported: false
        imageSupported: true
        inlineReplySupported: true
        persistenceSupported: true
        keepOnReload: true
        extraHints: ["sound"]
        onNotification: n => {
            if (root.service)
                root.service.receive(n);
        }
    }
}
