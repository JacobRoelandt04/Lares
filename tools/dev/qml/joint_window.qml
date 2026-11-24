import QtQuick
import Quickshell

// =============================================================================
// joint_window.qml -- a TILED window with nothing in it but a flat colour (tools/dev/shell_joint_probe.sh).
//
// A plain xdg toplevel: the nested Hyprland tiles it and draws its border and its rounded corners (`decoration:rounding`,
// `general:border_size`), and the probe measures where those corners stand against the shell's joints. Pure green, so its content,
// Hyprland's border (the probe makes it red) and the shell's surface are colours no mix of two can be taken for another. Smoked bare
// (offscreen, no compositor) it is a window nobody sees.
// =============================================================================
FloatingWindow {
    visible: true
    color: "#00A000"
    title: "joint-window"
}
