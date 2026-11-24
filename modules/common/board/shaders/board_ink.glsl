// coverage of a line `w` px wide at screen distance `dPx` from its centre
float inkLine(float dPx, float w) {
    return 1.0 - smoothstep(w * 0.5 - 0.5, w * 0.5 + 0.5, dPx);
}
