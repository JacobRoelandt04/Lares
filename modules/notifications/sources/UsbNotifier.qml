pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "SourceGlyphs.js" as G
import "UsbDrives.js" as Usb

// =============================================================================
// UsbNotifier.qml -- a removable drive came, was mounted, was unmounted, went (source "usb"; SOURCES.md, "Later sources").
//
// UDisks says WHEN: `udisksctl monitor` (a child kept alive by a SupervisedStream, under `setpriv --pdeathsig`) prints a
// line for every object that comes or goes; a line that names a UDisks2 object restarts a short wait, and when the
// devices have settled `lsblk -J -b` says WHAT (UsbDrives reads it, mount points included); a filesystem's own change (a
// mount, an unmount) is looked at at once (`mountLookMs`). The first look is the baseline: nothing is announced for a drive
// that was there -- except that a drive already MOUNTED gets its mounted card, since that card is a fact, not news.
// One card per drive, one key, four states; the card follows what the machine says, whoever mounted or unmounted:
//
//   connected   "SanDisk Ultra connected", "TESTDRIVE . 32 GB . exfat", Mount and Eject (a quiet card). The body click is
//               Mount. Mount = `udisksctl mount -b` on every filesystem of the drive (udisks puts them under /run/media/<user>,
//               which yazi's mount plugin can unmount with `udisksctl unmount -b`), then Open at the first mount point (`openAfterMount`).
//               Eject unmounts what is mounted and powers the drive off ("can be removed"; a failed unmount says why, a failed
//               power-off says "is unmounted", never the word safe).
//   mounted     "SanDisk Ultra mounted", "at /run/media/user/TESTDRIVE", Open and Unmount; the body click is Open. ANY
//               partition mounted, by this card or by anything else. The card is `kept` (the manager refuses to delete it and
//               shakes) for as long as the drive is mounted, and not persisted (the start posts it again). Open = the
//               `openCommand` setting (yazi in a kitty window, like Super+E), started detached through the host.
//               Unmount = `udisksctl unmount -b` on each mounted filesystem.
//   removable   "SanDisk Ultra can be removed", "Every filesystem on it is unmounted": nothing is mounted any more (by anyone) and the drive is
//               still there. No actions; it stays `safeSec` seconds (0: until the drive is pulled) and goes with the drive.
//   ejected     the same words after Eject powered the drive off: it outlives the drive by `safeSec` (the drive vanishes within a
//               second of the power-off), long enough to be read.
//
// A drive that vanishes while its card says "mounted" (no unmount) gets a card that says so: its files may be damaged
// (`unsafeWarn`). Nothing here changes the machine on its own: mount, unmount and power-off are the user's clicks; the
// whole-disk filesystem (no partition table) mounts too, but yazi's plugin cannot unmount that case. udisksctl and lsblk are
// the programs' own names (a test can put stubs ahead of them on PATH).
// =============================================================================
SourceBase {
    id: src

    sourceId: "usb"
    appName: "USB drive"
    glyph: G.usb
    keys: ["usb"]

    // The programs (the probes' seams).
    property string udisksctl: "udisksctl"
    property var lsblkCommand: ["lsblk", "-J", "-b", "-o", "PATH,NAME,LABEL,FSTYPE,SIZE,RM,HOTPLUG,TRAN,TYPE,PKNAME,MOUNTPOINTS,MODEL,VENDOR"]
    property var monitorCommand: ["setpriv", "--pdeathsig", "TERM", "--", src.udisksctl, "monitor"]
    property int debounceMs: src.settings.debounceMs
    // A change of a FILESYSTEM's properties (a mount, an unmount) is looked at at once, not after the quiet: an unmount
    // and the removal that follows it a moment later are two facts, and a look that waits for the quiet after the second
    // finds the drive gone with the picture of before the first -- "removed while mounted" about a drive another program
    // (a file manager, udiskie) ejected properly.
    property int mountLookMs: 80

    // The drives as of the last look (null: no baseline yet), and what each one's card is:
    // "connected" | "ejecting" | "mounted" | "removable" | "ejected"
    property var _known: null
    property var _card: ({})
    // "can be removed" cards waiting to go: key -> Timer
    property var _lingering: ({})

    function _key(d) {
        return "usb:" + d.id.replace(/[^A-Za-z0-9._@:+-]/g, "_");
    }

    SupervisedStream {
        id: stream
        enabled: src.active
        command: src.monitorCommand
        what: "UsbNotifier: udisksctl monitor"
        onLine: text => {
            if (text.indexOf("/org/freedesktop/UDisks2/") < 0)
                return;
            if (text.indexOf("org.freedesktop.UDisks2.Filesystem") >= 0)
                quick.restart();
            settle.restart();
        }
    }
    Timer {
        id: settle
        interval: src.debounceMs
        onTriggered: src._scan()
    }
    Timer {
        id: quick
        interval: src.mountLookMs
        onTriggered: src._scan()
    }

    function _scan() {
        if (!src.active)
            return;
        src.host.exec.run(src.lsblkCommand, (code, out) => {
            if (!src.active || code !== 0)
                return;
            const drives = Usb.parse(out);
            if (drives !== null)
                src._apply(drives);
        });
    }

    function _apply(drives) {
        if (src._known === null) {
            src._known = Usb.byId(drives);
            for (const x of drives)
                if (Usb.mountedAt(x) !== "")
                    src._mounted(x);
            return;
        }
        const d = Usb.diff(src._known, drives);
        const before = src._known;
        src._known = Usb.byId(drives);
        for (const x of d.plugged)
            if (Usb.mountedAt(x) !== "")
                src._mounted(x);
            else
                src._connected(x);
        for (const x of d.changed)
            src._changed(x);
        for (const x of d.unplugged)
            src._gone(before[x.id]);
    }

    // What the drive shows now, against what its card says.
    function _changed(x) {
        const was = src._card[x.id];
        const at = Usb.mountedAt(x) !== "";
        if (was === "ejecting" || was === "ejected")
            return;
        if (at)
            src._mounted(x);
        else if (was === "mounted")
            src._removable(x);
        else if (was === "connected" || was === "removable")
            src._connected(x);
    }

    function _actionsConnected(d) {
        const a = [];
        if (src.settings.mount)
            a.push({ id: "mount", label: "Mount", run: () => src.mount(d.id) });
        a.push({ id: "eject", label: "Eject", run: () => src.eject(d.id) });
        return a;
    }

    function _actionsMounted(d) {
        return [
            { id: "open", label: "Open", run: () => src.open(d.id) },
            { id: "unmount", label: "Unmount", run: () => src.unmount(d.id) }
        ];
    }

    function _connected(d) {
        const t = Usb.text(d);
        src._unlinger(src._key(d));
        src._card[d.id] = "connected";
        src.post(src._key(d), { title: t.title, body: t.body, urgency: "low", resident: true, actions: src._actionsConnected(d),
                                onDefault: src.settings.mount ? () => src.mount(d.id) : undefined });
    }

    function _mounted(d) {
        const t = Usb.mounted(d);
        src._unlinger(src._key(d));
        src._card[d.id] = "mounted";
        src.post(src._key(d), { title: t.title, body: t.body, urgency: "low", resident: true, kept: true, persist: false,
                                actions: src._actionsMounted(d), onDefault: () => src.open(d.id) });
    }

    function _removable(d) {
        const t = Usb.ejected(d);
        src._card[d.id] = "removable";
        src.post(src._key(d), { title: t.title, body: t.body, urgency: "low" });
        src._linger(src._key(d), false);
    }

    function _gone(d) {
        const was = src._card[d.id];
        delete src._card[d.id];
        if (was === "ejected") {
            src._linger(src._key(d), true);
            return;
        }
        if (was === "mounted" && src.settings.unsafeWarn && Usb.mountedAt(d) !== "") {
            src._unlinger(src._key(d));
            const t = Usb.lost(d);
            src.post(src._key(d), { title: t.title, body: t.body, urgency: "normal" });
            return;
        }
        src._unlinger(src._key(d));
        src.withdraw(src._key(d));
    }

    // ---- the "can be removed" card goes after it has been read -------------------------------------
    Component {
        id: lingerC
        Timer {
            id: tm
            property string key: ""
            running: true
            interval: Math.max(50, src.settings.safeSec * 1000)
            onTriggered: {
                src.withdraw(tm.key);
                delete src._lingering[tm.key];
                tm.destroy();
            }
        }
    }
    // `gone`: the drive has vanished (the ejected card outlives it by safeSec; with 0 it goes now). Not gone: the card
    // of a drive still there waits safeSec, or for ever with 0 (the drive's pulling ends it).
    function _linger(key, gone) {
        if (src._lingering[key])
            return;
        if (src.settings.safeSec <= 0) {
            if (gone)
                src.withdraw(key);
            return;
        }
        src._lingering[key] = lingerC.createObject(src, { key: key });
    }
    function _unlinger(key) {
        const t = src._lingering[key];
        if (t) {
            delete src._lingering[key];
            t.destroy();
        }
    }

    // ---- the clicks ---------------------------------------------------------------------
    // A refusal, said on the drive's own card: the buttons it had stay for another try (a mounted card stays kept).
    function _say(d, t, state) {
        src._card[d.id] = state;
        if (state === "mounted")
            src.post(src._key(d), { title: t.title, body: t.body, urgency: "normal", resident: true, kept: true, persist: false, actions: src._actionsMounted(d), onDefault: () => src.open(d.id) });
        else
            src.post(src._key(d), { title: t.title, body: t.body, urgency: "normal", resident: true, actions: src._actionsConnected(d) });
    }

    // Mount: every filesystem of the drive that nothing has mounted, one by one (udisks: /run/media/<user>/<label>), then
    // Open at the first mount point. The card moves to "mounted" by what the machine says next, not by this click.
    function mount(id) {
        const d = src._known ? src._known[id] : null;
        if (!d || !src.settings.mount)
            return;
        const todo = Usb.unmountedParts(d);
        if (todo.length === 0) {
            src.open(id);
            return;
        }
        let first = Usb.mountedAt(d);
        let lastErr = "";
        const next = i => {
            if (i < todo.length) {
                src.host.exec.run([src.udisksctl, "mount", "-b", todo[i].path], (code, out, err) => {
                    if (code === 0) {
                        if (first === "")
                            first = Usb.mountPathOf(out);
                    } else {
                        lastErr = err !== "" ? err : out;
                    }
                    next(i + 1);
                });
                return;
            }
            quick.restart();
            if (first !== "" && src.settings.openAfterMount)
                src._openAt(first);
            else if (first === "")
                src._say(d, Usb.failed(d, "mount", lastErr), "connected");
        };
        next(0);
    }

    // Open: the folder of the first mount point, in the user's file manager window.
    function open(id) {
        const d = src._known ? src._known[id] : null;
        if (!d)
            return;
        const at = Usb.mountedAt(d);
        if (at !== "")
            src._openAt(at);
    }

    function _openAt(path) {
        src.host.run(Usb.openArgv(src.settings.openCommand, path), { detached: true });
    }

    // Unmount: every mounted filesystem (`udisksctl unmount -b`, the way yazi's plugin does it); the card follows the machine.
    function unmount(id) {
        const d = src._known ? src._known[id] : null;
        if (!d)
            return;
        const mounted = Usb.mountedParts(d);
        const next = i => {
            if (i >= mounted.length) {
                quick.restart();
                return;
            }
            src.host.exec.run([src.udisksctl, "unmount", "-b", mounted[i].path], (code, out, err) => {
                if (code !== 0) {
                    quick.restart();
                    src._say(src._known && src._known[id] ? src._known[id] : d, Usb.failed(d, "unmount", err !== "" ? err : out), "mounted");
                } else {
                    next(i + 1);
                }
            });
        };
        next(0);
    }

    // Eject: unmount what is mounted, one by one, then power the drive off.
    function eject(id) {
        const d = src._known ? src._known[id] : null;
        if (!d)
            return;
        const mounted = Usb.mountedParts(d);
        src._card[d.id] = "ejecting";
        const next = i => {
            if (i < mounted.length) {
                src.host.exec.run([src.udisksctl, "unmount", "-b", mounted[i].path], (code, out, err) => {
                    if (code !== 0)
                        src._say(d, Usb.failed(d, "eject", err !== "" ? err : out), "connected");
                    else
                        next(i + 1);
                });
                return;
            }
            src.host.exec.run([src.udisksctl, "power-off", "-b", d.id], (code, out, err) => {
                if (code !== 0) {
                    src._say(d, Usb.unmounted(d, err !== "" ? err : out), "connected");
                    return;
                }
                const t = Usb.ejected(d);
                src._card[d.id] = "ejected";
                src.post(src._key(d), { title: t.title, body: t.body, urgency: "low" });
                // the drive may have vanished before udisksctl came back to say so
                if (!src._known || !src._known[d.id])
                    src._linger(src._key(d), true);
            });
        };
        next(0);
    }

    onActivated: {
        src._known = null;
        src._card = ({});
        src._scan();
    }
    onDeactivated: {
        settle.stop();
        quick.stop();
        src._known = null;
        for (const k in src._lingering)
            src._lingering[k].destroy();
        src._lingering = ({});
    }
}
