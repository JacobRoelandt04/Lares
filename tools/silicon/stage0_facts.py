#!/usr/bin/env python3
"""stage0_facts.py -- read-only snapshot of every machine fact silicon's design waits on.

    tools/silicon/stage0_facts.py [OUT_JSON]     (default tools/dev/fixtures/silicon/stage0_facts.json)

Reads sysfs/procfs, runs read-only commands (busctl get/call of cardwire's READ methods,
systemctl is-*, pkcheck WITHOUT user interaction, modinfo) and writes one JSON file.
Never writes /sys, never sets a cardwire mode, never runs nvidia-smi (it would wake the dGPU).
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tools/dev/fixtures/silicon/stage0_facts.json")
CW = "org.opengamingcollective.cardwire"
CWP = "/org/opengamingcollective/cardwire"


def rd(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as e:
        return {"error": e.strerror}


def run(argv, timeout=10, env=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
        return {"rc": p.returncode, "out": p.stdout.strip(), "err": p.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"rc": None, "error": str(e)}


def busctl(*args):
    r = run(["busctl", "--system", "--json=short", *args])
    if r.get("rc") == 0:
        try:
            r["json"] = json.loads(r["out"])
        except ValueError:
            pass
    return r


def cpulist(s):
    out = []
    if not isinstance(s, str):
        return out
    for part in s.split(","):
        if "-" in part:
            a, b = part.split("-")
            out += list(range(int(a), int(b) + 1))
        elif part:
            out.append(int(part))
    return out


facts = {"taken": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "kernel": os.uname().release}

# --- identity -------------------------------------------------------------------------
facts["dmi"] = {k: rd(f"/sys/class/dmi/id/{k}") for k in
                ("board_name", "product_name", "sys_vendor", "bios_version", "bios_date")}
facts["cmdline"] = rd("/proc/cmdline")

# --- topology: P / E / LPE ----------------------------------------------------------------
cpus = sorted(int(m.group(1)) for d in glob.glob("/sys/devices/system/cpu/cpu[0-9]*")
              if (m := re.search(r"cpu(\d+)$", d)))
core = cpulist(rd("/sys/devices/cpu_core/cpus"))
atom = cpulist(rd("/sys/devices/cpu_atom/cpus"))
topo = []
for c in cpus:
    l3 = os.path.exists(f"/sys/devices/system/cpu/cpu{c}/cache/index3")
    kind = "P" if c in core else ("E" if l3 else "LPE") if c in atom else "?"
    topo.append({"cpu": c, "kind": kind, "core_id": rd(f"/sys/devices/system/cpu/cpu{c}/topology/core_id"),
                 "siblings": rd(f"/sys/devices/system/cpu/cpu{c}/topology/thread_siblings_list"), "l3": l3})
facts["topology"] = topo
facts["topology_summary"] = {k: [t["cpu"] for t in topo if t["kind"] == k] for k in ("P", "E", "LPE", "?")}
facts["sibling_pairs"] = sorted({t["siblings"] for t in topo if t["kind"] == "P"})

# --- CPU knobs ----------------------------------------------------------------------------
pols = sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*"), key=lambda p: int(p.rsplit("y", 1)[1]))
def uniq(key):
    vals = {}
    for p in pols:
        vals.setdefault(rd(f"{p}/{key}") if not isinstance(rd(f"{p}/{key}"), dict) else "ERR", []).append(os.path.basename(p))
    return vals
avail = [set(rd(f"{p}/energy_performance_available_preferences").split()) for p in pols]
facts["cpufreq"] = {
    "policies": len(pols),
    "driver": uniq("scaling_driver"),
    "governor": uniq("scaling_governor"),
    "governors_available": uniq("scaling_available_governors"),
    "epp": uniq("energy_performance_preference"),
    "epp_available_intersection": sorted(set.intersection(*avail)) if avail else [],
    "max_freq_khz": uniq("cpuinfo_max_freq"),
    "base_freq_khz": uniq("base_frequency"),
}
facts["intel_pstate"] = {k: rd(f"/sys/devices/system/cpu/intel_pstate/{k}") for k in
                         ("status", "no_turbo", "min_perf_pct", "max_perf_pct", "hwp_dynamic_boost")}

# --- platform profile, ASUS WMI, RAPL --------------------------------------------------
facts["platform_profile"] = {
    "legacy": {"profile": rd("/sys/firmware/acpi/platform_profile"),
               "choices": rd("/sys/firmware/acpi/platform_profile_choices")},
    "class": {os.path.basename(d): {k: rd(f"{d}/{k}") for k in ("name", "choices", "profile")}
              for d in glob.glob("/sys/class/platform-profile/*")},
}
facts["asus_wmi"] = {k: rd(f"/sys/devices/platform/asus-nb-wmi/{k}") for k in
                     ("gpu_mux_mode", "throttle_thermal_policy", "dgpu_disable", "egpu_enable")}
facts["firmware_attributes"] = sorted(glob.glob("/sys/class/firmware-attributes/*/attributes/*"))
rapl = {}
for z in ("intel-rapl:0", "intel-rapl-mmio:0"):
    d = f"/sys/class/powercap/{z}"
    if not os.path.exists(d):
        continue
    zone = {"name": rd(f"{d}/name"), "enabled": rd(f"{d}/enabled")}
    for c in range(4):
        if os.path.exists(f"{d}/constraint_{c}_name"):
            zone[rd(f"{d}/constraint_{c}_name")] = {
                "limit_uw": rd(f"{d}/constraint_{c}_power_limit_uw"),
                "window_us": rd(f"{d}/constraint_{c}_time_window_us"),
                "max_uw": rd(f"{d}/constraint_{c}_max_power_uw"),
                "mode": oct(os.stat(f"{d}/constraint_{c}_power_limit_uw").st_mode & 0o777)}
    rapl[z] = zone
facts["rapl"] = rapl

# --- battery, AC, sensors, GPUs -----------------------------------------------------------
facts["battery"] = {k: rd(f"/sys/class/power_supply/BAT0/{k}") for k in
                    ("status", "capacity", "charge_control_end_threshold", "energy_now", "energy_full",
                     "energy_full_design", "power_now", "voltage_now", "voltage_min_design", "cycle_count")}
facts["ac_online"] = rd("/sys/class/power_supply/AC0/online")
hw = {}
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    hw[os.path.basename(h)] = rd(f"{h}/name")
facts["hwmon"] = hw
cards = {}
for card in sorted(glob.glob("/sys/class/drm/card[0-9]")):
    dev = os.path.realpath(f"{card}/device")
    drv = os.path.basename(os.path.realpath(f"{dev}/driver")) if os.path.exists(f"{dev}/driver") else None
    cards[os.path.basename(card)] = {"pci": os.path.basename(dev), "driver": drv,
                                    "rc6": sorted(glob.glob(f"{os.path.realpath(card)}/gt/gt*/rc6_residency_ms")),
                                    "power_state": rd(f"{dev}/power_state"),
                                    "runtime_status": rd(f"{dev}/power/runtime_status")}
facts["drm_cards"] = cards
facts["connectors"] = {os.path.basename(c): rd(f"{c}/status") for c in glob.glob("/sys/class/drm/card[0-9]-*")}

# --- nvidia module + DKMS per installed kernel -------------------------------------------
facts["nvidia_loaded_version"] = rd("/sys/module/nvidia/version")
dkms = {}
for kdir in sorted(glob.glob("/usr/lib/modules/*")):
    ko = sorted(glob.glob(f"{kdir}/updates/dkms/nvidia.ko*"))
    entry = {"pkgbase": rd(f"{kdir}/pkgbase"), "nvidia_ko": ko}
    if ko:
        entry["version"] = run(["modinfo", "-F", "version", ko[0]]).get("out")
    dkms[os.path.basename(kdir)] = entry
facts["kernels"] = dkms
facts["grubenv"] = rd("/boot/grub/grubenv")

# --- services + asusd config -------------------------------------------------------------
svc = {}
for u in ("asusd", "asus-boot-quiet", "asus-power-fix", "asus-shutdown", "cardwired",
          "nvidia-persistenced", "nvidia-powerd", "powertop", "power-profiles-daemon", "upower"):
    svc[u] = {"active": run(["systemctl", "is-active", u]).get("out"),
              "enabled": run(["systemctl", "is-enabled", u]).get("out")}
facts["services"] = svc
facts["asusd_ron"] = rd("/etc/asusd/asusd.ron")

# --- cardwire (READ methods only) --------------------------------------------------------
cw = {
    "cli_get": run(["cardwire", "get"]),
    "cli_list": run(["cardwire", "list"]),
    "Mode": busctl("get-property", CW, CWP, f"{CW}.Mode", "Mode"),
    "AvailableModes": busctl("call", CW, CWP, f"{CW}.Mode", "AvailableModes"),
    "GetAppPolicies": busctl("call", CW, CWP, f"{CW}.SmartPolicy", "GetAppPolicies"),
    "ProcessBlocked": busctl("call", CW, CWP, f"{CW}.Logger", "ProcessBlocked"),
    "Config": {p: busctl("get-property", CW, CWP, f"{CW}.Config", p) for p in
               ("AutoApplyGpuState", "BatteryAutoSwitch", "BatteryAutoSwitchMode",
                "ExperimentalNvidiaBlock", "ExternalDisplayAutoSwitch")},
    "Gpu": {},
}
for g in ("0", "1"):
    gp = f"{CWP}/Gpu/{g}"
    cw["Gpu"][g] = {
        "GetDevice": busctl("call", CW, gp, f"{CW}.Gpu", "GetDevice"),
        "PowerState": busctl("call", CW, gp, f"{CW}.Gpu", "PowerState"),
        "Lsof": busctl("call", CW, gp, f"{CW}.Gpu", "Lsof"),
        "Block": busctl("get-property", CW, gp, f"{CW}.Gpu", "Block"),
        "Launchable": busctl("get-property", CW, gp, f"{CW}.Gpu", "Launchable"),
        "Env": busctl("get-property", CW, gp, f"{CW}.Gpu", "Env"),
    }
facts["cardwire"] = cw

# --- where the shell's processes live (polkit subject) -----------------------------------
procs = []
ps = run(["ps", "-C", "quickshell,qs", "-o", "pid=,args="])
for line in (ps.get("out") or "").splitlines():
    pid = line.strip().split()[0]
    procs.append({"pid": pid, "args": line.strip()[len(pid):].strip()[:160],
                  "cgroup": rd(f"/proc/{pid}/cgroup"),
                  "session_id_env": next((v.split("=", 1)[1] for v in
                                          (open(f"/proc/{pid}/environ").read().split("\0") if os.access(f"/proc/{pid}/environ", os.R_OK) else [])
                                          if v.startswith("XDG_SESSION_ID=")), None)})
facts["shell_processes"] = procs
facts["this_terminal"] = {"cgroup": rd("/proc/self/cgroup"), "XDG_SESSION_ID": os.environ.get("XDG_SESSION_ID")}
facts["loginctl_sessions"] = run(["loginctl", "list-sessions", "--no-legend"]).get("out")
pk = {}
for action in ("org.freedesktop.login1.suspend", "org.freedesktop.login1.reboot"):
    pk[action] = {
        "terminal": run(["bash", "-c", f"pkcheck --action-id {action} --process $$; echo rc=$?"]),
        # --expand-environment=no: systemd-run expands its argv like a unit file ($$ -> $)
        "user_service": run(["systemd-run", "--user", "--wait", "--pipe", "--quiet", "--expand-environment=no",
                             "bash", "-c", f"pkcheck --action-id {action} --process $$; echo rc=$?"], timeout=20),
    }
facts["pkcheck"] = pk

# --- which charger: the OS view of USB-C (UCSI) beside the one ACPI supply -------------------
facts["power_supplies"] = {os.path.basename(d): {k: rd(f"{d}/{k}") for k in ("type", "online", "usb_type")}
                           for d in sorted(glob.glob("/sys/class/power_supply/*"))}
facts["typec_ports"] = sorted(os.path.basename(p) for p in glob.glob("/sys/class/typec/port*"))
facts["ucsi_kernel_lines"] = [l for l in (run(["journalctl", "-k", "-b", "--no-pager", "-o", "cat"], timeout=20).get("out") or "").splitlines()
                              if "ucsi" in l.lower() or "typec" in l.lower()][:20]

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(facts, f, indent=1, sort_keys=False)
print("wrote", OUT)
