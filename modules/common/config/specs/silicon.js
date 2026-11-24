.pragma library

// The spec of config/silicon.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/silicon.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var PROFILE = (epp, turbo) => ({
    epp: ["word", epp, ["power", "balance_power", "balance_performance", "performance", "default"], { null: true }],
    turbo: ["bool", turbo, { null: true }],
    governor: ["text", "powersave", { null: true }],
    maxPerfPct: ["int", null, 1, 100],
    pl1W: ["num", null, 1, 400],
    pl2W: ["num", null, 1, 400]
});
var SPEC = {
    defaultProfile: ["word", null, ["quiet", "balanced", "performance"]],
    profiles: {
        quiet: PROFILE("power", false),
        balanced: PROFILE("balance_power", true),
        performance: PROFILE("performance", true)
    },
    onPower: { ac: ["word", null, ["quiet", "balanced", "performance"]], battery: ["word", null, ["quiet", "balanced", "performance"]] },
    holds: { systemUpdate: ["word", "performance", ["performance", "balanced"], { null: true }] },
    battery: { lowAt: ["int", 15, 5, 50] },
    fans: { guard: ["bool", true], resumeKick: ["bool", true] },
    sounds: ["bool", true],
    interactionBoost: ["bool", false],
    overhead: { wPerCpuSec: ["num", 2.0, 0, 50], wPerGpuSec: ["num", 5.0, 0, 50] },
    gpu: {
        askWhenBusy: ["bool", true],
        blockedNotice: ["bool", true],
        ignoredHolders: ["list", ["cardwired", "nvidia-persiste", "nvidia-persistenced", "hyprland", "xwayland", "xorg", "systemd", "systemd-logind",
            "btop", "nvidia-smi", "quickshell"], ["text", undefined], { max: 64 }]
    },
    look: { family: ["word", "material", ["material", "blueprint", "eva"]], secondarySide: ["word", "far", ["far", "start", "end"]] }
};
