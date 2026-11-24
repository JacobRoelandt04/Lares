#!/usr/bin/env bash
# capture_sysfs.sh -- copy this machine's power-knob tree into a fixture (READ-ONLY on /sys).
#
#   tools/silicon/capture_sysfs.sh [OUT_DIR]
#   default OUT_DIR: helpers/silicon_helper/tests/fixtures/<board>_<kernel-tag>
#
# The fixture is what silicon-helper's tests run against instead of /sys: the same paths,
# relative under OUT_DIR (OUT_DIR/sys/devices/...), the same class/bus symlinks (relative,
# so the tree works wherever it is checked out), the values as they were at capture time.
# git keeps neither file modes nor sysfs semantics, so two side files carry them:
#   modes.txt  "<octal mode> <path>"  -- tests chmod from it (a 0444 knob is a locked knob)
#   links.txt  "<path> -> <target>"   -- what each symlink pointed at on the machine
# Files the user cannot read (energy_uj 0400, cpufv 0200) are created EMPTY and keep their
# mode in modes.txt: their contents are a side channel and are never copied.
#
# Runs as a normal user. Writes nothing outside OUT_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
board="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
ktag="$(uname -r | sed -E 's/^([0-9]+)\.([0-9]+).*-(lts)$/\1\2\3/; s/^([0-9]+)\.([0-9]+)\..*$/\1\2/')"
OUT="${1:-$ROOT/helpers/silicon_helper/tests/fixtures/${board}_${ktag}}"

if [[ $EUID -eq 0 ]]; then echo "capture_sysfs: run as your user, not root" >&2; exit 2; fi
rm -rf "$OUT"; mkdir -p "$OUT"
: > "$OUT/modes.txt"; : > "$OUT/links.txt"

n_files=0; n_empty=0
copy_file() {  # $1 = absolute path of a real (non-symlink) sysfs file
    local src="$1" dst="$OUT${1}"
    [[ -e "$src" && ! -d "$src" ]] || return 0
    mkdir -p "$(dirname "$dst")"
    printf '%s %s\n' "$(stat -c '%a' "$src")" "$src" >> "$OUT/modes.txt"
    if [[ -r "$src" ]] && cat "$src" > "$dst" 2>/dev/null; then
        n_files=$((n_files + 1))
    else
        : > "$dst"; n_empty=$((n_empty + 1))
    fi
}
copy_glob() { local f; for f in "$@"; do [[ -e "$f" ]] && copy_file "$(readlink -f "$f")"; done; return 0; }

link() {  # $1 = symlink path on the machine; recreate it relative inside OUT
    local path="$1" target rel
    [[ -L "$path" ]] || return 0
    target="$(readlink -f "$path")"
    printf '%s -> %s\n' "$path" "$target" >> "$OUT/links.txt"
    mkdir -p "$OUT$(dirname "$path")" "$OUT$target"
    rel="$(realpath --relative-to="$(dirname "$path")" "$target")"
    ln -sfn "$rel" "$OUT$path"
}

shopt -s nullglob

# CPU frequency policies + intel_pstate
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    for k in affected_cpus related_cpus scaling_driver scaling_governor scaling_available_governors \
             energy_performance_preference energy_performance_available_preferences \
             scaling_min_freq scaling_max_freq cpuinfo_min_freq cpuinfo_max_freq base_frequency; do
        copy_glob "$pol/$k"
    done
done
copy_glob /sys/devices/system/cpu/intel_pstate/{status,no_turbo,min_perf_pct,max_perf_pct,hwp_dynamic_boost}
copy_glob /sys/devices/system/cpu/{online,possible,present}
# Topology: P vs E (hybrid PMU lists), LPE = no L3 cache
copy_glob /sys/devices/cpu_core/cpus /sys/devices/cpu_atom/cpus
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    copy_glob "$c/topology/core_id" "$c/topology/thread_siblings_list" "$c/topology/cluster_id"
    copy_glob "$c/cache/index3/shared_cpu_list"
done

# Platform profile: legacy file + class device (+ its symlink)
copy_glob /sys/firmware/acpi/platform_profile /sys/firmware/acpi/platform_profile_choices
for pp in /sys/class/platform-profile/*; do
    link "$pp"; copy_glob "$pp/name" "$pp/choices" "$pp/profile"
done

# ASUS WMI (mux, thermal policy; cpufv is write-only and stays empty)
copy_glob /sys/devices/platform/asus-nb-wmi/{gpu_mux_mode,throttle_thermal_policy,cpufv,dgpu_disable,egpu_enable,panel_od,mini_led_mode}

# Firmware attributes (asus-armoury on newer kernels)
for fa in /sys/class/firmware-attributes/*; do
    link "$fa"
    for a in "$fa"/attributes/*; do
        # an attribute is a directory of values -- or, like pending_reboot, a plain file of its own
        if [[ -d "$a" ]]; then copy_glob "$a/current_value" "$a/possible_values" "$a/min_value" "$a/max_value" "$a/default_value"
        else copy_glob "$a"; fi
    done
done

# RAPL, both interfaces, plus the subzones' names
for z in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0 \
         /sys/class/powercap/intel-rapl:0:0 /sys/class/powercap/intel-rapl:0:1; do
    [[ -e "$z" ]] || continue
    link "$z"
    copy_glob "$z/name" "$z/enabled" "$z/max_energy_range_uj" "$z/energy_uj"
    for c in 0 1 2 3; do
        copy_glob "$z/constraint_${c}_name" "$z/constraint_${c}_power_limit_uw" \
                  "$z/constraint_${c}_time_window_us" "$z/constraint_${c}_max_power_uw"
    done
done

# Power supplies
for ps in /sys/class/power_supply/*; do
    link "$ps"
    copy_glob "$ps/type" "$ps/online" "$ps/status" "$ps/capacity" "$ps/charge_control_end_threshold" \
              "$ps/charge_control_start_threshold" "$ps/charge_behaviour" \
              "$ps/energy_now" "$ps/energy_full" "$ps/energy_full_design" "$ps/power_now" \
              "$ps/voltage_now" "$ps/voltage_min_design" "$ps/cycle_count" "$ps/model_name" \
              "$ps/manufacturer" "$ps/technology" "$ps/uevent"
done

# hwmon (names everywhere; coretemp labels + inputs)
for h in /sys/class/hwmon/*; do
    link "$h"; copy_glob "$h/name"
    if [[ "$(cat "$h/name" 2>/dev/null)" == coretemp ]]; then copy_glob "$h"/temp*_label "$h"/temp*_input; fi
done

# DRM cards: device + driver links, i915 rc6 residency
for card in /sys/class/drm/card[0-9]; do
    link "$card"
    real="$(readlink -f "$card")"
    link "$real/device"
    dev="$(readlink -f "$real/device")"
    link "$dev/driver"
    copy_glob "$dev/vendor" "$dev/device" "$dev/class" "$dev/power_state" \
              "$dev/power/runtime_status" "$dev/power/control" "$dev/d3cold_allowed" "$dev/boot_vga"
    copy_glob "$real"/gt/gt*/rc6_residency_ms "$real"/gt/gt*/rc6_enable
done
for conn in /sys/class/drm/card[0-9]-*; do link "$conn"; copy_glob "$conn/status"; done
link /sys/bus/pci/devices/0000:01:00.0

# Modules and DMI
copy_glob /sys/module/nvidia/version /sys/module/nvidia_drm/version
link /sys/class/dmi/id
copy_glob /sys/class/dmi/id/{board_name,board_vendor,product_name,product_family,sys_vendor,bios_version,bios_date}

cat > "$OUT/CAPTURE.txt" <<EOF
captured: $(date -Iseconds)
kernel:   $(uname -r)
board:    $(cat /sys/class/dmi/id/board_name 2>/dev/null) / bios $(cat /sys/class/dmi/id/bios_version 2>/dev/null)
files:    $n_files copied, $n_empty unreadable (created empty, mode kept in modes.txt)
links:    $(wc -l < "$OUT/links.txt")
EOF
cat "$OUT/CAPTURE.txt"
echo "out: $OUT"
