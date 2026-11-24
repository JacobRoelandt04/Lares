// =============================================================================
// curtain_desk.glsl -- the live curtain's still (ThemeWipe.qml). Declared by the includer: sampler2D shot, shellThen.
// =============================================================================
// THE DESKTOP WITHOUT THE SHELL. The output's capture is the shell over the desktop, and the shell's own picture of that frame says how much:
// shot = shell + (1 - shell.a) * desktop, so desktop = (shot - shell) / (1 - shell.a). Where the shell was opaque nothing of the desktop is
// in the capture: alpha 0 here. curtain_under fills that from the coarse levels of this same picture (`shotFill`): if a popup leaves, what shows
// until the line arrives is the old desktop's colours, soft, and not a rectangle of the new theme.
vec4 curtainDesk(vec2 uv) {
    vec4 s = texture(shot, uv);
    vec4 p = texture(shellThen, uv);
    float k = 1.0 - p.a;
    if (k < 0.012)
        return vec4(0.0);
    return vec4(clamp((s.rgb - p.rgb) / k, 0.0, 1.0), 1.0);
}
