pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "IconResolve.js" as R

// =============================================================================
// AppIcons.qml -- the shell's one answer to "which picture is this app's mark" (IconResolve.js has the rules and the order).
//
//   AppIcons.source({ cls: "kitty", appId: "kitty.desktop", icon: "kitty", kind: "app" })   -> an image source url
//
// A BINDING THAT CALLS source() reads `serial`, so a change of the user's overrides re-answers it. The ICON THEME itself cannot
// change under a running Quickshell (Qt takes the name once, at start: QS_ICON_THEME, which tools/shell/lares-supervise exports
// from gsettings -- the one place GTK and themectl keep it); Papirus-Light and Papirus-Dark share every app icon (their apps/ are
// links to Papirus'), so a light/dark switch moves no mark here.
//
// CONFIG. shell.jsonc "icons": { "overrides": { "<class | desktop id | icon name>": "<path | theme name>" }, "fallback": "<theme name>" }
// -- ShellServices binds the parsed file to `config` (hot, like the rest of the file); a mockup or a probe leaves the defaults, or sets
// `config` (or `overrides` through setOverrides) itself.
// =============================================================================
QtObject {
    id: root

    // The parsed shell.jsonc (ShellConfig.raw): its `icons` block is read, anything else ignored.
    property var config: null
    onConfigChanged: {
        const ic = root.config && typeof root.config === "object" ? root.config.icons : null;
        const ok = ic && typeof ic === "object" && !Array.isArray(ic);
        root.setOverrides(ok ? ic.overrides : null);
        root.fallbackName = ok && typeof ic.fallback === "string" && ic.fallback !== "" ? ic.fallback : "application-x-executable";
    }
    // key (lower case) -> a path (~ allowed) or a theme icon name
    property var overrides: ({})
    // The one icon shown when nothing else resolves (the theme's; the shell's own asset when the theme lacks it too).
    property string fallbackName: "application-x-executable"
    readonly property string archLogo: "/usr/share/pixmaps/archlinux-logo.svg"
    readonly property string fallbackAsset: Qt.resolvedUrl("fallback.svg")

    // Bumps when overrides or the fallback change. Read it first in a binding.
    readonly property int serial: root._serial
    property int _serial: 0
    onOverridesChanged: root._serial++
    onFallbackNameChanged: root._serial++

    readonly property string _home: Quickshell.env("HOME") || ""

    // Normalises what shell.jsonc wrote (any object) into the lower-cased map the rules read.
    function setOverrides(o: var): void {
        const out = {};
        if (o && typeof o === "object" && !Array.isArray(o)) {
            for (const k in o) {
                if (typeof o[k] === "string" && o[k] !== "")
                    out[String(k).toLowerCase().replace(/\.desktop$/, "")] = o[k];
            }
        }
        root.overrides = out;
    }

    // `Quickshell.iconPath(s, true)` that says nothing about a missing SVG. QIcon reads an absolute path as a file and the check answers "" for one that is gone, but an .svg goes
    // through Qt's SVG renderer first, which logs `qt.svg: Cannot open file` at every ask (hasThemeIcon too, measured) -- and a desktop entry's Icon= outliving its app is common
    // (a removed winapps left /home/.../winapps/icons/windows.svg). So such a path is read here first, by a reader that keeps quiet. Nothing is kept: a file that comes back shows.
    property Component _reader: Component {
        FileView {
            blockLoading: true
            blockAllReads: true
            printErrors: false
        }
    }
    function checkedPath(s: string): string {
        if (s.charAt(0) === "/" && /\.svgz?$/i.test(s)) {
            const f = root._reader.createObject(root, { path: s }) as FileView;
            const there = f.text().length > 0;
            f.destroy();
            if (!there)
                return "";
        }
        return Quickshell.iconPath(s, true);
    }

    function _env(): var {
        return {
            has: n => Quickshell.hasThemeIcon(n),
            path: n => Quickshell.iconPath(n),
            file: p => root.checkedPath(p) !== "" ? "file://" + encodeURI(p) : "",
            overrides: root.overrides,
            fallbackName: root.fallbackName,
            archLogo: root.archLogo,
            fallbackAsset: root.fallbackAsset,
            home: root._home
        };
    }

    // -> { url, how }: the image source and the rule that answered ("arch" | "override" | "path" | "name" | "script" | "fallback" |
    // "asset"; probes and tips read the second). Cheap (a few string compares and a theme lookup Qt caches).
    function resolve(q: var): var {
        root._serial;
        return R.resolve(q, root._env());
    }
    function source(q: var): string {
        return root.resolve(q).url;
    }
}
