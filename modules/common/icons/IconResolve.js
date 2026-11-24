// =============================================================================
// IconResolve.js -- which picture an app's mark is, in one place (pure; the singleton AppIcons wires it to Quickshell).
//
// Every app icon of the shell is the icon the ACTIVE ICON THEME gives (the theme GTK reports: themectl writes gsettings and
// settings.ini, lares-supervise hands the name to Quickshell at start). Nothing is processed, baked or cached.
// What there is to decide per mark is only WHICH name, and what to show when the theme has none:
//
//   query    { cls, appId, icon, kind }
//              cls    the window class ("~desktop": no window, "~locked": the locked face)
//              appId  the .desktop id ("" when there is none)
//              icon   the entry's Icon= value / a script's `# icon:` header: a theme name, an absolute path, a file:// url, or ""
//              kind   "app" | "script" | "desktop" | "folder" | "" (the launcher's rows)
//              archFallback  true: nothing resolved -> the Arch mark instead of the generic fallback (the window title's: a window that
//                            provides no icon gets the Arch mark, as the locked face does)
//   env      { has(name) -> bool, path(name) -> url, file(path) -> url|"" (the url when the file is there),
//              overrides {key -> path|name}, fallbackName, archLogo, fallbackAsset, home }
//
// THE ORDER (first that answers):
//   1. `~desktop` / `~locked`            the Arch mark (/usr/share/pixmaps/archlinux-logo.svg, the `filesystem` package's own)
//   2. an OVERRIDE of the user's          shell.jsonc "icons": { "overrides": { "kitty": "~/.config/kitty/kitty.app.png" } }: matched,
//                                         lower-cased, against the class, the desktop id (without .desktop) and the icon name
//   3. a path or file:// url              when the file is there
//   4. a theme NAME                       only when the theme HAS it (hasThemeIcon): Quickshell hands back a path for a name the theme
//                                         lacks too, and what the Image shows for it is a purple and black checkerboard
//   5. a script with no icon of its own   `text-x-script`
//   6. the ONE fallback                   env.fallbackName in the theme, else the shell's own asset (a theme without even that)
// A script whose header names an icon the theme lacks gets 5, not the fallback: it is a script.
// =============================================================================
.pragma library

var ARCH_LOGO = "/usr/share/pixmaps/archlinux-logo.svg";

function _norm(s) {
    return String(s === undefined || s === null ? "" : s).toLowerCase();
}

function _expand(p, home) {
    p = String(p);
    if (p === "~" || p.indexOf("~/") === 0)
        return String(home || "") + p.substring(1);
    return p;
}

function _fileUrl(p, env) {
    return env.file(p);
}

// -> { url, how }. `how` names the rule that answered (probes read it; the Image never does).
function resolve(q, env) {
    q = q || {};
    const cls = String(q.cls || "");
    if (cls === "~desktop" || cls === "~locked") {
        const u = _fileUrl(env.archLogo || ARCH_LOGO, env);
        if (u !== "")
            return { url: u, how: "arch" };
    }

    const ov = env.overrides || {};
    const keys = [_norm(cls), _norm(String(q.appId || "").replace(/\.desktop$/i, "")), _norm(q.icon)];
    for (let i = 0; i < keys.length; i++) {
        if (keys[i] === "" || ov[keys[i]] === undefined)
            continue;
        const v = _expand(ov[keys[i]], env.home);
        if (v.charAt(0) === "/") {
            const u = _fileUrl(v, env);
            if (u !== "")
                return { url: u, how: "override" };
        } else if (env.has(v)) {
            return { url: env.path(v), how: "override" };
        }
        // an override that points nowhere is no override: the rest of the rules answer
    }

    const icon = String(q.icon || "");
    if (icon !== "") {
        if (icon.indexOf("file://") === 0 || icon.charAt(0) === "/") {
            const p = icon.indexOf("file://") === 0 ? decodeURIComponent(icon.substring(7)) : icon;
            const u = _fileUrl(p, env);
            if (u !== "")
                return { url: u, how: "path" };
        } else if (env.has(icon)) {
            return { url: env.path(icon), how: "name" };
        }
    }

    if (q.kind === "script" && env.has("text-x-script"))
        return { url: env.path("text-x-script"), how: "script" };

    if (q.archFallback) {
        const u = _fileUrl(env.archLogo || ARCH_LOGO, env);
        if (u !== "")
            return { url: u, how: "arch" };
    }
    if (env.fallbackName && env.has(env.fallbackName))
        return { url: env.path(env.fallbackName), how: "fallback" };
    return { url: env.fallbackAsset || "", how: "asset" };
}
