pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "SenderMatch.js" as SenderMatch

// =============================================================================
// AppLookup.qml -- a Hyprland window class as an app, once. (Screentime and
// the clipboard shelf resolve their apps with this same lookup.)
//
//   app(cls) -> { desktopId, name, icon, categories, resolved }
//
// `desktopId` is the .desktop id ("" when no entry was found), `name` the entry's
// Name (else the class made readable: the part after the last dot, first letter
// capitalised -- the digest's rule), `icon` the entry's Icon NAME
// (what the entry says; AppIcons resolves it, this asks for nothing), `categories` its Categories. `~desktop` -- the daemon's
// "no window focused" -- is {name: "Desktop"} (its mark is the Arch logo: AppIcons) and
// has no entry. `resolved` is true when an entry answered.
//
// THE LOOKUP, in order: DesktopEntries.heuristicLookup(class); the same on the
// class lowercased and ".desktop"-stripped (SenderMatch.norm); an entry whose
// StartupWMClass is the class; an entry whose id's last dot segment is the class
// ("discord" against com.discordapp.Discord -- Flatpaks and KDE do this both
// ways); the class's own last dot segment ("org.kde.konsole" -> "konsole").
// heuristicLookup resolves kitty, zen and com.microsoft.VSCode.
//
// THE SCAN. Quickshell reads the desktop entries lazily, from the first lookup,
// and that lookup answers null: this starts the scan at creation and, while the
// applications list is still empty, answers a fallback that is NOT cached. When
// the list arrives the cache is dropped and `serial` bumps, so a binding that
// read `app()` (which reads `serial`) asks again. An answer taken after the scan
// -- found or not -- is cached per class: a lookup is a handful of string
// compares, but a list of rows asks every frame it is rebuilt.
//
// A getter that is called from a binding reads and resolves; it never starts a
// load. The cache is a `var` mutated in place (the counting-instrument rule's
// cousin: nothing here is a property a binding could watch).
// =============================================================================
QtObject {
    id: root

    // Bumps when the desktop entries arrive or change. Read it first in a binding.
    readonly property int serial: root._serial
    // True once the applications list has been seen non-empty.
    readonly property bool scanned: root._scanned
    // Lookups that missed the cache (a probe's instrument; a var, mutated in place).
    readonly property var counters: ({ resolved: 0 })

    property int _serial: 0
    property bool _scanned: false
    property var _cache: ({})

    function app(cls: string): var {
        root._serial;                              // the dependency
        const key = String(cls === undefined || cls === null ? "" : cls);
        const hit = root._cache[key];
        if (hit)
            return hit;
        const out = root._resolve(key);
        // Before the scan the answer is provisional, so it is not remembered.
        if (root._scanned || key === "~desktop" || key === "")
            root._cache[key] = out;
        return out;
    }

    function _pretty(cls: string): string {
        const i = cls.lastIndexOf(".");
        const t = i >= 0 && i < cls.length - 1 ? cls.substring(i + 1) : cls;
        return t.length > 0 ? t.charAt(0).toUpperCase() + t.substring(1) : cls;
    }

    function _list(v: var): var {
        const out = [];
        if (v === undefined || v === null)
            return out;
        for (let i = 0; i < v.length; i++)
            out.push(String(v[i]));
        return out;
    }

    function _find(cls: string): var {
        const n = SenderMatch.norm(cls);
        if (n === "")
            return null;
        let e = DesktopEntries.heuristicLookup(cls);
        if (!e && n !== cls)
            e = DesktopEntries.heuristicLookup(n);
        if (e)
            return e;
        const vals = DesktopEntries.applications.values;
        const dot = n.lastIndexOf(".");
        const tail = dot >= 0 ? n.substring(dot + 1) : "";
        let weak = null;
        for (let i = 0; i < vals.length; i++) {
            const id = SenderMatch.norm(vals[i].id);
            if (id === n || SenderMatch.norm(vals[i].startupClass) === n)
                return vals[i];
            const idDot = id.lastIndexOf(".");
            if (weak === null && ((idDot >= 0 && id.substring(idDot + 1) === n) || (tail !== "" && id === tail)))
                weak = vals[i];
        }
        return weak;
    }

    function _resolve(cls: string): var {
        root.counters.resolved++;
        if (cls === "~desktop")
            return { desktopId: "", name: "Desktop", icon: "", categories: [], resolved: false };
        const e = root._scanned ? root._find(cls) : null;
        if (!e)
            return { desktopId: "", name: root._pretty(cls), icon: "", categories: [], resolved: false };
        return { desktopId: String(e.id), name: String(e.name || root._pretty(cls)), icon: String(e.icon || ""),
                 categories: root._list(e.categories), resolved: true };
    }

    function _seen(): void {
        const has = DesktopEntries.applications.values.length > 0;
        if (!has)
            return;
        root._scanned = true;
        root._cache = ({});
        root._serial++;
    }

    property Connections _scan: Connections {
        target: DesktopEntries.applications
        function onValuesChanged(): void {
            root._seen();
        }
    }

    Component.onCompleted: {
        // Start the lazy scan; the lookup itself answers null.
        DesktopEntries.byId("");
        root._seen();
    }
}
