.pragma library

// HyprWs.js -- the identity of a workspace in what Hyprland says.
//
// Hyprland 0.57 gives a special or named workspace no number any more: `hyprctl -j` answers { address: "special:default", type: "special", name: ... }
// with no `id`, the events carry the name in the id's field ("special:default,special:default,eDP-1", "dev,dev"), and Quickshell's own
// workspace object reads id -1 for it. Up to 0.56 it was a negative id. So a workspace's key is its number when it has one, else its name,
// and 0 for "none" (`{ address: "", type: "", name: "" }`, the monitor's specialWorkspace with nothing shown, or an empty event).
function key(w) {
    if (!w)
        return 0;
    const id = w.id;
    if (id !== undefined && id !== null && id !== "" && isFinite(Number(id)))
        return Number(id);
    if (w.name)
        return String(w.name);
    return id ? String(id) : 0;
}
