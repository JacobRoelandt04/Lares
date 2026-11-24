#!/usr/bin/env python3
"""A stand-in for the cardwire GPU daemon's D-Bus service (cardwire 0.12.3).

Owns `org.opengamingcollective.cardwire` on a PRIVATE session bus, answering from the replies
recorded on the real daemon (tools/dev/fixtures/silicon/cardwire/spike_replies.json and
tools/dev/fixtures/silicon/stage0_facts.json), so the silicon module's data layer can read cardwire, set
its mode / config / policies and watch its signals with no real cardwire involved. A second name,
`org.lares.CardwireStub`, is how a TEST drives the stub (it is not part of cardwire).

START (never on a real bus: the stub refuses unless DBUS_SESSION_BUS_ADDRESS is the private bus
of tools/dev/notifications_bus.sh, and never talks to the system bus at all):

    tools/dev/notifications_bus.sh python3 tools/dev/stubs/silicon/cardwire_stub.py     # no arguments

    CARDWIRE_STUB_LOG=<file>       append one line per event (format below)
    CARDWIRE_STUB_FIXTURES=<dir>   the fixtures root (default: ../../fixtures/silicon beside this file)

It prints `cardwire-stub ready` on stdout once both names are owned, and exits 0 on `Quit`,
SIGTERM/SIGINT or when the bus goes away (1 when a name cannot be owned, 2 when it refuses to start).

THE CARDWIRE SURFACE (object /org/opengamingcollective/cardwire, and .../Gpu/0 + .../Gpu/1):
    Config       SaveToFile(); props AutoApplyGpuState b, BatteryAutoSwitch b, BatteryAutoSwitchMode u,
                 ExperimentalNvidiaBlock b, ExternalDisplayAutoSwitch b (all rw, emit PropertiesChanged)
    Debug        GetPciDevices() -> a{s(sssssssss)} (empty: nothing was recorded), RefreshGpu()
    Logger       ProcessBlocked() -> a((tu)usus); signal ProcessBlockedChanged ((tu)usus) from the ROOT path
    Manager      Status()
    Mode         AvailableModes() -> au; prop Mode u (rw)
    SmartPolicy  GetAppPolicies() -> a{s(sasasu)}, GetProcessStatus(u) -> (s, au) = ("Default", []),
                 RequestProcessAccess(usu), SetAppPolicy(si), signal NewAppAdded (s(sasasu))
    Gpu (on Gpu/0, Gpu/1)  GetDevice() -> ssuubbbbssbs as TWELVE out args, Lsof() -> a{sas}, PowerState() -> s;
                 props Block b (rw), Env as, Launchable b; signal PowerStateChanged s (from Gpu/1)
    org.freedesktop.DBus.{Introspectable,Peer,Properties,ObjectManager} (GetManagedObjects on the root)
  A set of Mode is accepted only when the value is in the CURRENT AvailableModes, else the call fails with
  org.freedesktop.DBus.Error.Failed and the daemon's own words (read from cardwired's embedded strings:
  "Couldn't set mode to Smart, Integrated and Smart modes require a offload discrete GPU (not supported on
  desktops where the discrete GPU is the primary display)"). A property set with the wrong D-Bus type,
  or of a read-only property, fails too. SetAppPolicy takes policy 0 or 1 of a known app only.
  PowerState() answers the sysfs text ("D3cold\\n"); the signal spells the Rust Debug name without the
  newline ('D3Cold', 'D3Hot').

CONTROL (org.lares.CardwireStub, /org/lares/cardwire_stub, interface
org.lares.CardwireStub.Control). Every method answers at once; the signals it causes go out BEFORE the
reply, so a caller that returns from the call has a signal already on the bus.
    EmitPowerState(s state)     D0|D1|D2|D3hot|D3cold (any case): Gpu/1's PowerState + PowerStateChanged
    SetLsof(s json)             {"/dev/nvidia0": ["cardwired", ...], ...} replaces Gpu/1's Lsof table
    SetAvailable(s json)        [1] replaces AvailableModes; Mode is NOT touched
    SetMode(u mode)             Mode without the availability check + PropertiesChanged (an external change)
    SetConfig(s key, s json)    a Config property without any check of the daemon + PropertiesChanged
    EmitBlocked(u pid, s comm, u gpuId, s appId)    append to ProcessBlocked() + ProcessBlockedChanged (now)
    EmitNewApp(s id, s name, u policy)              add the app (desktopIds [id], icons []) + NewAppAdded
    SetPolicies(s json)         {"id": ["Name", ["desktop"], ["icon"], policy], ...} replaces the table
    Reset()                     the initial state again (no signal)
    Dump() -> s                 JSON: mode, available, config, policies, power (Gpu/1, "D3cold"), lsof (Gpu/1),
                                blocked, gpus ([{device, power (raw), lsof, block, launchable, env}, ...]),
                                calls ({"<iface>.<Method>": count} of every logged CALL since the last Reset)
    Quit()                      reply, then exit 0
  A bad argument is a D-Bus error (InvalidArgs), nothing changes.

LOG (CARDWIRE_STUB_LOG; one line per event, flushed at once; <ms> = unix milliseconds; JSON is compact):
    <ms> CALL <interface>.<Method> <object-path> <json args>        every method call, reads too
                                                                    (Properties.Get / GetAll included; a Set is a SET)
    <ms> SET <interface>.<Prop> <json value>                        every property write; ` REFUSED <message>` when refused
    <ms> EMIT <interface>.<Signal> <object-path> <json args>        every signal the stub emits
    <ms> CONTROL <Method> <json args>                               every control call (` REFUSED <message>` when bad)
"""
import copy
import json
import os
import re
import signal
import sys
import time
import traceback

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
gi.require_version("GLibUnix", "2.0")
from gi.repository import Gio, GLib, GLibUnix

BUS = "org.opengamingcollective.cardwire"
ROOT = "/org/opengamingcollective/cardwire"
GPU_PATHS = [ROOT + "/Gpu/0", ROOT + "/Gpu/1"]
I_CONFIG = BUS + ".Config"
I_DEBUG = BUS + ".Debug"
I_GPU = BUS + ".Gpu"
I_LOGGER = BUS + ".Logger"
I_MANAGER = BUS + ".Manager"
I_MODE = BUS + ".Mode"
I_SMART = BUS + ".SmartPolicy"
I_PROPS = "org.freedesktop.DBus.Properties"
I_OBJMAN = "org.freedesktop.DBus.ObjectManager"
CTL_NAME = "org.lares.CardwireStub"
CTL_PATH = "/org/lares/cardwire_stub"
I_CTL = "org.lares.CardwireStub.Control"

E_FAILED = "org.freedesktop.DBus.Error.Failed"
E_ARGS = "org.freedesktop.DBus.Error.InvalidArgs"
E_IFACE = "org.freedesktop.DBus.Error.UnknownInterface"
E_PROP = "org.freedesktop.DBus.Error.UnknownProperty"
E_RO = "org.freedesktop.DBus.Error.PropertyReadOnly"

MODE_NAMES = ["Integrated", "Hybrid", "Manual", "Smart"]

# The spelling of a power state: the method's sysfs text, the signal's Rust Debug name (the real
# daemon differs between the two, and so does the shell's reader).
POWER = {
    "d0": ("D0\n", "D0"),
    "d1": ("D1\n", "D1"),
    "d2": ("D2\n", "D2"),
    "d3hot": ("D3hot\n", "D3Hot"),
    "d3cold": ("D3cold\n", "D3Cold"),
}

# interface -> {property: (D-Bus type, writable)}; every one of them emits PropertiesChanged
PROPS = {
    I_CONFIG: {
        "AutoApplyGpuState": ("b", True),
        "BatteryAutoSwitch": ("b", True),
        "BatteryAutoSwitchMode": ("u", True),
        "ExperimentalNvidiaBlock": ("b", True),
        "ExternalDisplayAutoSwitch": ("b", True),
    },
    I_MODE: {"Mode": ("u", True)},
    I_GPU: {"Block": ("b", True), "Env": ("as", False), "Launchable": ("b", False)},
}
# object path -> the interfaces it carries (a Get of any other one is UnknownInterface)
OBJECT_IFACES = {
    ROOT: [I_CONFIG, I_DEBUG, I_LOGGER, I_MANAGER, I_MODE, I_SMART],
    GPU_PATHS[0]: [I_GPU],
    GPU_PATHS[1]: [I_GPU],
}

# --- introspection -----------------------------------------------------------------------------------


def _emits(name, typ, access):
    return ("<property name='%s' type='%s' access='%s'>"
            "<annotation name='org.freedesktop.DBus.Property.EmitsChangedSignal' value='true'/></property>"
            % (name, typ, access))


def _args(types, direction):
    return "".join("<arg type='%s' direction='%s'/>" % (t, direction) for t in types)


# GDBus hands Properties to its own handler unless an interface of that very name is registered on the
# path; registering ours routes Get / GetAll / Set to the stub, which is the only way to answer a refused
# Set with the daemon's own error name and words (a vtable setter can only say "Unable to set property").
PROPS_XML = """
 <interface name='org.freedesktop.DBus.Properties'>
  <method name='Get'><arg type='s' name='interface_name' direction='in'/><arg type='s' name='property_name' direction='in'/><arg type='v' name='value' direction='out'/></method>
  <method name='GetAll'><arg type='s' name='interface_name' direction='in'/><arg type='a{sv}' name='properties' direction='out'/></method>
  <method name='Set'><arg type='s' name='interface_name' direction='in'/><arg type='s' name='property_name' direction='in'/><arg type='v' name='value' direction='in'/></method>
  <signal name='PropertiesChanged'><arg type='s' name='interface_name'/><arg type='a{sv}' name='changed_properties'/><arg type='as' name='invalidated_properties'/></signal>
 </interface>"""

ROOT_XML = ("<node>"
            "<interface name='%(config)s'><method name='SaveToFile'/>%(config_props)s</interface>"
            "<interface name='%(debug)s'><method name='GetPciDevices'>%(pci)s</method><method name='RefreshGpu'/></interface>"
            "<interface name='%(logger)s'><method name='ProcessBlocked'>%(blocked)s</method>"
            "<signal name='ProcessBlockedChanged'><arg type='((tu)usus)' name='log'/></signal></interface>"
            "<interface name='%(manager)s'><method name='Status'/></interface>"
            "<interface name='%(mode)s'><method name='AvailableModes'>%(modes)s</method>%(mode_prop)s</interface>"
            "<interface name='%(smart)s'>"
            "<method name='GetAppPolicies'>%(apps)s</method>"
            "<method name='GetProcessStatus'><arg type='u' name='pid' direction='in'/>%(status)s</method>"
            "<method name='RequestProcessAccess'><arg type='u' name='pid' direction='in'/>"
            "<arg type='s' name='policy' direction='in'/><arg type='u' name='value' direction='in'/></method>"
            "<method name='SetAppPolicy'><arg type='s' name='app_id' direction='in'/><arg type='i' name='policy' direction='in'/></method>"
            "<signal name='NewAppAdded'><arg type='(s(sasasu))' name='new_app'/></signal></interface>"
            "<interface name='%(objman)s'><method name='GetManagedObjects'>%(managed)s</method>"
            "<signal name='InterfacesAdded'><arg type='o'/><arg type='a{sa{sv}}'/></signal>"
            "<signal name='InterfacesRemoved'><arg type='o'/><arg type='as'/></signal></interface>"
            + PROPS_XML + "</node>") % {
    "config": I_CONFIG, "debug": I_DEBUG, "logger": I_LOGGER, "manager": I_MANAGER, "mode": I_MODE,
    "smart": I_SMART, "objman": I_OBJMAN,
    "config_props": "".join(_emits(n, t, "readwrite") for n, (t, _) in PROPS[I_CONFIG].items()),
    "mode_prop": _emits("Mode", "u", "readwrite"),
    "pci": _args(["a{s(sssssssss)}"], "out"),
    "blocked": _args(["a((tu)usus)"], "out"),
    "modes": _args(["au"], "out"),
    "apps": _args(["a{s(sasasu)}"], "out"),
    "status": _args(["s", "au"], "out"),
    "managed": _args(["a{oa{sa{sv}}}"], "out"),
}

GPU_XML = ("<node><interface name='%s'>"
           "<method name='GetDevice'>%s</method>"
           "<method name='Lsof'>%s</method><method name='PowerState'>%s</method>"
           "%s%s%s<signal name='PowerStateChanged'><arg type='s' name='state'/></signal></interface>"
           % (I_GPU, _args(list("ssuubbbbssbs"), "out"), _args(["a{sas}"], "out"), _args(["s"], "out"),
              _emits("Block", "b", "readwrite"), _emits("Env", "as", "read"), _emits("Launchable", "b", "read"))
           + PROPS_XML + "</node>")

CTL_XML = ("<node><interface name='%s'>"
           "<method name='EmitPowerState'><arg type='s' name='state' direction='in'/></method>"
           "<method name='SetLsof'><arg type='s' name='json' direction='in'/></method>"
           "<method name='SetAvailable'><arg type='s' name='json' direction='in'/></method>"
           "<method name='SetMode'><arg type='u' name='mode' direction='in'/></method>"
           "<method name='SetConfig'><arg type='s' name='key' direction='in'/><arg type='s' name='json' direction='in'/></method>"
           "<method name='EmitBlocked'><arg type='u' name='pid' direction='in'/><arg type='s' name='comm' direction='in'/>"
           "<arg type='u' name='gpu_id' direction='in'/><arg type='s' name='app_id' direction='in'/></method>"
           "<method name='EmitNewApp'><arg type='s' name='id' direction='in'/><arg type='s' name='name' direction='in'/>"
           "<arg type='u' name='policy' direction='in'/></method>"
           "<method name='SetPolicies'><arg type='s' name='json' direction='in'/></method>"
           "<method name='Reset'/>"
           "<method name='Dump'><arg type='s' name='json' direction='out'/></method>"
           "<method name='Quit'/>"
           "</interface></node>" % I_CTL)

# --- small helpers -----------------------------------------------------------------------------------


class DBusFail(Exception):
    """A refused call: becomes a D-Bus error reply of this name and message."""

    def __init__(self, name, message):
        super().__init__(message)
        self.name = name
        self.message = message


def jdump(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False, default=str)


def die(message, code=2):
    sys.stderr.write("cardwire-stub: %s\n" % message)
    sys.stderr.flush()
    sys.exit(code)


def is_uint(v):
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 0xFFFFFFFF


def parse_json(text, what):
    try:
        return json.loads(text)
    except ValueError as e:
        raise DBusFail(E_ARGS, "%s is not JSON: %s" % (what, e))


def mode_refusal(n, available):
    name = MODE_NAMES[n] if 0 <= n < len(MODE_NAMES) else str(n)
    if n in (0, 3):
        return ("Couldn't set mode to %s, Integrated and Smart modes require a offload discrete GPU "
                "(not supported on desktops where the discrete GPU is the primary display)" % name)
    return "Couldn't set mode to %s: it is not one of the available modes %s" % (name, jdump(available))


# --- the private-bus guard ---------------------------------------------------------------------------

_PRIVATE_ADDRESS = re.compile(r"^unix:(path|abstract)=/tmp/dbus-[A-Za-z0-9]+(,|$)")


def private_bus_address():
    """DBUS_SESSION_BUS_ADDRESS, only when it is the private bus of tools/dev/notifications_bus.sh.

    The stub connects to exactly this address (never through `Gio.bus_get`, which falls back to the
    user's own bus when the variable is missing) and has no code path to the system bus."""
    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not _PRIVATE_ADDRESS.match(addr):
        die("refusing to run: DBUS_SESSION_BUS_ADDRESS is %r, not the private test bus -- start it with "
            "tools/dev/notifications_bus.sh python3 tools/dev/stubs/silicon/cardwire_stub.py" % addr)
    return addr


def refuse_a_real_daemon(conn):
    """The address says private; the daemon behind it must agree: a private bus is a dbus-daemon started
    with --config-file (tools/dev/notifications_bus.sh), the user's own is systemd-activated."""
    try:
        reply = conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                               "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.freedesktop.DBus",)),
                               GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
        with open("/proc/%d/cmdline" % reply.unpack()[0], "rb") as f:
            argv = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
    except (GLib.Error, OSError):
        return  # the daemon's command line cannot be read: the address guard stands
    configured = any(a == "--config-file" or a.startswith("--config-file=") for a in argv)
    if not configured or "--systemd-activation" in argv or "--system" in argv or any(a.startswith("--address=systemd") for a in argv):
        die("refusing to run: the bus daemon (%s) is not a private tools/dev/notifications_bus.sh daemon" % " ".join(argv))


# --- the recorded initial state ----------------------------------------------------------------------


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        die("cannot read the recorded fixture %s: %s" % (path, e))


def load_initial(fixdir):
    """The daemon's state as recorded: spike_replies.json is the authority for what busctl printed for the
    root object (and for Gpu/1's PowerState and Lsof, whose dictionary order it keeps byte for byte);
    stage0_facts.json holds the rest of Gpu/0 + Gpu/1 and the ProcessBlocked log."""
    spike = _read_json(os.path.join(fixdir, "cardwire", "spike_replies.json"))
    facts = _read_json(os.path.join(fixdir, "stage0_facts.json"))
    try:
        facts = facts["cardwire"]

        def recorded(key):                      # a busctl --json=short reply -> its `data`
            return json.loads(spike[key])["data"]

        gpus = []
        for n in ("0", "1"):
            g = facts["Gpu"][n]
            gpus.append({
                "device": g["GetDevice"]["json"]["data"],
                "power": g["PowerState"]["json"]["data"][0],
                "lsof": g["Lsof"]["json"]["data"][0],
                "block": g["Block"]["json"]["data"],
                "launchable": g["Launchable"]["json"]["data"],
                "env": g["Env"]["json"]["data"],
            })
        gpus[1]["power"] = recorded("power")[0]
        gpus[1]["lsof"] = recorded("lsof")[0]
        init = {
            "mode": recorded("mode"),
            "available": recorded("modes")[0],
            "config": {k[len("cfg."):]: recorded(k) for k in spike if k.startswith("cfg.")},
            "policies": {k: [v[0], list(v[1]), list(v[2]), v[3]] for k, v in recorded("policies")[0].items()},
            "gpus": gpus,
            "blocked": facts["ProcessBlocked"]["json"]["data"][0],
        }
    except (KeyError, IndexError, TypeError, ValueError) as e:
        die("the recorded fixtures under %s do not have the expected shape: %r" % (fixdir, e))
    if sorted(init["config"]) != sorted(PROPS[I_CONFIG]):
        die("the recorded Config properties %s are not the stub's %s" % (sorted(init["config"]), sorted(PROPS[I_CONFIG])))
    return init


class State:
    """Everything the daemon reports, one copy per Reset()."""

    def __init__(self, init):
        d = copy.deepcopy(init)
        self.mode = d["mode"]
        self.available = d["available"]
        self.config = d["config"]
        self.policies = d["policies"]          # app id -> [display name, [desktop ids], [icons], policy]
        self.gpus = d["gpus"]                  # device (12 values), power (sysfs text), lsof, block, launchable, env
        self.blocked = d["blocked"]            # [[secs, nanos], pid, comm, gpu id, wayland app id] ...
        self.calls = {}                        # "<interface>.<Method>" -> how many times it was called

    def prop(self, path, iface, name):
        if iface == I_MODE:
            return self.mode
        if iface == I_CONFIG:
            return self.config[name]
        g = self.gpus[GPU_PATHS.index(path)]
        return {"Block": g["block"], "Env": g["env"], "Launchable": g["launchable"]}[name]

    def set_prop(self, path, iface, name, value):
        if iface == I_MODE:
            self.mode = value
        elif iface == I_CONFIG:
            self.config[name] = value
        else:
            self.gpus[GPU_PATHS.index(path)]["block"] = value

    def dump(self):
        g1 = self.gpus[1]
        return {
            "mode": self.mode,
            "available": self.available,
            "config": self.config,
            "policies": self.policies,
            "power": g1["power"].strip(),
            "lsof": g1["lsof"],
            "blocked": self.blocked,
            "gpus": [{"device": g["device"], "power": g["power"], "lsof": g["lsof"], "block": g["block"],
                      "launchable": g["launchable"], "env": g["env"]} for g in self.gpus],
            "calls": self.calls,
        }


# --- the service -------------------------------------------------------------------------------------


class Stub:
    def __init__(self, conn, init, log_path):
        self.conn = conn
        self.init = init
        self.state = State(init)
        self.logf = self.open_log(log_path)
        self.loop = GLib.MainLoop()
        self.exit_code = 0
        self.owned = set()
        self.methods = {
            (I_CONFIG, "SaveToFile"): self.m_noop,
            (I_DEBUG, "GetPciDevices"): self.m_pci_devices,
            (I_DEBUG, "RefreshGpu"): self.m_noop,
            (I_LOGGER, "ProcessBlocked"): self.m_process_blocked,
            (I_MANAGER, "Status"): self.m_noop,
            (I_MODE, "AvailableModes"): self.m_available_modes,
            (I_SMART, "GetAppPolicies"): self.m_app_policies,
            (I_SMART, "GetProcessStatus"): self.m_process_status,
            (I_SMART, "RequestProcessAccess"): self.m_noop,
            (I_SMART, "SetAppPolicy"): self.m_set_app_policy,
            (I_GPU, "GetDevice"): self.m_get_device,
            (I_GPU, "Lsof"): self.m_lsof,
            (I_GPU, "PowerState"): self.m_power_state,
            (I_OBJMAN, "GetManagedObjects"): self.m_managed_objects,
        }
        self.controls = {
            "EmitPowerState": self.c_emit_power_state,
            "SetLsof": self.c_set_lsof,
            "SetAvailable": self.c_set_available,
            "SetMode": self.c_set_mode,
            "SetConfig": self.c_set_config,
            "EmitBlocked": self.c_emit_blocked,
            "EmitNewApp": self.c_emit_new_app,
            "SetPolicies": self.c_set_policies,
            "Reset": self.c_reset,
            "Dump": self.c_dump,
            "Quit": self.c_quit,
        }

    # -- log and signals --

    @staticmethod
    def open_log(path):
        if not path:
            return None
        try:
            return open(path, "a", buffering=1, encoding="utf-8")
        except OSError as e:
            die("cannot open CARDWIRE_STUB_LOG %s: %s" % (path, e))

    def log(self, kind, text):
        if self.logf:
            self.logf.write("%d %s %s\n" % (time.time() * 1000, kind, text))
            self.logf.flush()

    def emit(self, path, iface, member, variant):
        self.log("EMIT", "%s.%s %s %s" % (iface, member, path, jdump(variant.unpack())))
        self.conn.emit_signal(None, path, iface, member, variant)

    def emit_changed(self, path, iface, changes):
        self.emit(path, I_PROPS, "PropertiesChanged", GLib.Variant(
            "(sa{sv}as)", (iface, {k: GLib.Variant(PROPS[iface][k][0], v) for k, v in changes.items()}, [])))

    def count(self, key):
        self.state.calls[key] = self.state.calls.get(key, 0) + 1

    # -- dispatch --

    def on_method_call(self, conn, sender, path, iface, method, params, inv):
        try:
            if path == CTL_PATH:
                reply = self.control_call(method, params)
            elif iface == I_PROPS:
                reply = self.properties_call(path, method, params)
            else:
                args = params.unpack()
                key = "%s.%s" % (iface, method)
                self.count(key)
                self.log("CALL", "%s %s %s" % (key, path, jdump(args)))
                fn = self.methods.get((iface, method))
                if fn is None:
                    raise DBusFail(E_FAILED, "%s is not implemented by the stub" % key)
                reply = fn(path, args)
        except DBusFail as e:
            inv.return_dbus_error(e.name, e.message)
            return
        except Exception as e:  # a stub bug must not leave the caller waiting for its timeout
            traceback.print_exc()
            inv.return_dbus_error(E_FAILED, "cardwire-stub internal error: %r" % (e,))
            return
        inv.return_value(reply)

    # -- cardwire methods --

    def m_noop(self, path, args):
        return None

    def m_pci_devices(self, path, args):
        return GLib.Variant("(a{s(sssssssss)})", ({},))

    def m_process_blocked(self, path, args):
        return GLib.Variant("(a((tu)usus))", ([((e[0][0], e[0][1]), e[1], e[2], e[3], e[4]) for e in self.state.blocked],))

    def m_available_modes(self, path, args):
        return GLib.Variant("(au)", (list(self.state.available),))

    def m_app_policies(self, path, args):
        return GLib.Variant("(a{s(sasasu)})", ({k: (v[0], list(v[1]), list(v[2]), v[3])
                                                 for k, v in self.state.policies.items()},))

    def m_process_status(self, path, args):
        return GLib.Variant("(sau)", ("Default", []))

    def m_set_app_policy(self, path, args):
        app, policy = args
        if policy not in (0, 1):
            raise DBusFail(E_ARGS, "policy must be 0 or 1")
        if app not in self.state.policies:
            raise DBusFail(E_FAILED, "unknown app")
        self.state.policies[app][3] = policy
        return None

    def m_get_device(self, path, args):
        return GLib.Variant("(ssuubbbbssbs)", tuple(self.state.gpus[GPU_PATHS.index(path)]["device"]))

    def m_lsof(self, path, args):
        return GLib.Variant("(a{sas})", ({k: list(v) for k, v in self.state.gpus[GPU_PATHS.index(path)]["lsof"].items()},))

    def m_power_state(self, path, args):
        return GLib.Variant("(s)", (self.state.gpus[GPU_PATHS.index(path)]["power"],))

    def m_managed_objects(self, path, args):
        return GLib.Variant("(a{oa{sa{sv}}})", ({p: {I_GPU: {n: self.prop_variant(p, I_GPU, n) for n in PROPS[I_GPU]}}
                                                 for p in GPU_PATHS},))

    # -- org.freedesktop.DBus.Properties --

    def prop_variant(self, path, iface, name):
        return GLib.Variant(PROPS[iface][name][0], self.state.prop(path, iface, name))

    @staticmethod
    def known_interface(path, iface):
        if iface not in OBJECT_IFACES.get(path, []):
            raise DBusFail(E_IFACE, "No such interface '%s'" % iface)

    def properties_call(self, path, method, params):
        if method == "Set":
            return self.property_set(path, params)
        args = params.unpack()
        key = "%s.%s" % (I_PROPS, method)
        self.count(key)
        self.log("CALL", "%s %s %s" % (key, path, jdump(args)))
        iface = args[0]
        self.known_interface(path, iface)
        if method == "Get":
            if args[1] not in PROPS.get(iface, {}):
                raise DBusFail(E_PROP, "No such property '%s'" % args[1])
            return GLib.Variant("(v)", (self.prop_variant(path, iface, args[1]),))
        return GLib.Variant("(a{sv})", ({n: self.prop_variant(path, iface, n) for n in PROPS.get(iface, {})},))

    def property_set(self, path, params):
        iface = params.get_child_value(0).get_string()
        name = params.get_child_value(1).get_string()
        var = params.get_child_value(2).get_variant()
        value = var.unpack()
        key = "%s.%s" % (iface, name)
        try:
            self.known_interface(path, iface)
            if name not in PROPS.get(iface, {}):
                raise DBusFail(E_PROP, "No such property '%s'" % name)
            typ, writable = PROPS[iface][name]
            if not writable:
                raise DBusFail(E_RO, "Property '%s' is not writable" % name)
            if var.get_type_string() != typ:
                raise DBusFail(E_ARGS, "Invalid type for property '%s': expected '%s', got '%s'"
                               % (name, typ, var.get_type_string()))
            if iface == I_MODE and value not in self.state.available:
                raise DBusFail(E_FAILED, mode_refusal(value, self.state.available))
        except DBusFail as e:
            self.log("SET", "%s %s REFUSED %s" % (key, jdump(value), e.message))
            raise
        self.log("SET", "%s %s" % (key, jdump(value)))
        self.state.set_prop(path, iface, name, value)
        self.emit_changed(path, iface, {name: value})
        return None

    # -- control --

    def control_call(self, method, params):
        args = params.unpack()
        text = "%s %s" % (method, jdump(args))
        fn = self.controls.get(method)
        try:
            if fn is None:
                raise DBusFail(E_FAILED, "unknown control method %s" % method)
            apply = fn(*args)                   # validates, changes nothing, hands back what to do
        except DBusFail as e:
            self.log("CONTROL", "%s REFUSED %s" % (text, e.message))
            sys.stderr.write("cardwire-stub: control %s refused: %s\n" % (method, e.message))
            raise
        self.log("CONTROL", text)
        return apply()

    def c_emit_power_state(self, state):
        key = str(state).lower()
        if key not in POWER:
            raise DBusFail(E_ARGS, "unknown power state %r (D0, D1, D2, D3hot or D3cold)" % state)
        sysfs, debug = POWER[key]

        def apply():
            self.state.gpus[1]["power"] = sysfs
            self.emit(GPU_PATHS[1], I_GPU, "PowerStateChanged", GLib.Variant("(s)", (debug,)))
        return apply

    def c_set_lsof(self, text):
        table = parse_json(text, "Lsof table")
        if not isinstance(table, dict) or not all(
                isinstance(v, list) and all(isinstance(s, str) for s in v) for v in table.values()):
            raise DBusFail(E_ARGS, 'Lsof table must be {"/dev/node": ["process", ...], ...}')

        def apply():
            self.state.gpus[1]["lsof"] = table
        return apply

    def c_set_available(self, text):
        modes = parse_json(text, "AvailableModes")
        if not isinstance(modes, list) or not all(is_uint(m) for m in modes):
            raise DBusFail(E_ARGS, "AvailableModes must be a JSON array of unsigned integers, e.g. [0,1,3]")

        def apply():
            self.state.available = modes
        return apply

    def c_set_mode(self, mode):
        def apply():
            self.state.mode = mode
            self.emit_changed(ROOT, I_MODE, {"Mode": mode})
        return apply

    def c_set_config(self, key, text):
        if key not in PROPS[I_CONFIG]:
            raise DBusFail(E_ARGS, "unknown Config property %r (%s)" % (key, ", ".join(PROPS[I_CONFIG])))
        value = parse_json(text, "the value of %s" % key)
        if PROPS[I_CONFIG][key][0] == "b":
            ok = isinstance(value, bool)
        else:
            ok = is_uint(value)
        if not ok:
            raise DBusFail(E_ARGS, "%s takes D-Bus type '%s', not %s" % (key, PROPS[I_CONFIG][key][0], text))

        def apply():
            self.state.config[key] = value
            self.emit_changed(ROOT, I_CONFIG, {key: value})
        return apply

    def c_emit_blocked(self, pid, comm, gpu_id, app_id):
        def apply():
            secs, nanos = divmod(time.time_ns(), 1000000000)
            self.state.blocked.append([[secs, nanos], pid, comm, gpu_id, app_id])
            self.emit(ROOT, I_LOGGER, "ProcessBlockedChanged",
                      GLib.Variant("(((tu)usus))", (((secs, nanos), pid, comm, gpu_id, app_id),)))
        return apply

    def c_emit_new_app(self, app_id, name, policy):
        def apply():
            self.state.policies[app_id] = [name, [app_id], [], policy]
            self.emit(ROOT, I_SMART, "NewAppAdded",
                      GLib.Variant("((s(sasasu)))", ((app_id, (name, [app_id], [], policy)),)))
        return apply

    def c_set_policies(self, text):
        table = parse_json(text, "the policy table")
        shape = 'the policy table must be {"id": ["Name", ["desktop id"], ["icon"], policy], ...}'
        if not isinstance(table, dict):
            raise DBusFail(E_ARGS, shape)
        for v in table.values():
            if not (isinstance(v, list) and len(v) == 4 and isinstance(v[0], str)
                    and isinstance(v[1], list) and all(isinstance(s, str) for s in v[1])
                    and isinstance(v[2], list) and all(isinstance(s, str) for s in v[2]) and is_uint(v[3])):
                raise DBusFail(E_ARGS, shape)

        def apply():
            self.state.policies = table
        return apply

    def c_reset(self):
        def apply():
            self.state = State(self.init)
        return apply

    def c_dump(self):
        return lambda: GLib.Variant("(s)", (jdump(self.state.dump()),))

    def c_quit(self):
        def apply():
            GLib.idle_add(self.finish)           # after the reply has gone out
        return apply

    def finish(self):
        try:
            self.conn.flush_sync(None)
        except GLib.Error:
            pass
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    # -- names and lifetime --

    def on_acquired(self, conn, name):
        self.owned.add(name)
        if self.owned == {BUS, CTL_NAME}:
            print("cardwire-stub ready", flush=True)

    def on_lost(self, conn, name):
        if not self.conn.is_closed():
            sys.stderr.write("cardwire-stub: could not own (or lost) the bus name %s\n" % name)
            self.exit_code = 1
        self.loop.quit()

    def on_closed(self, conn, remote_vanished, error):
        self.loop.quit()

    def on_signal(self, *args):
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    def run(self):
        reg = getattr(self.conn, "register_object_with_closures2", None) or self.conn.register_object
        for path, xml in ((ROOT, ROOT_XML), (GPU_PATHS[0], GPU_XML), (GPU_PATHS[1], GPU_XML), (CTL_PATH, CTL_XML)):
            for ifc in Gio.DBusNodeInfo.new_for_xml(xml).interfaces:
                reg(path, ifc, self.on_method_call, None, None)
        self.conn.connect("closed", self.on_closed)
        for sig in (signal.SIGTERM, signal.SIGINT):
            GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, sig, self.on_signal)
        for name in (BUS, CTL_NAME):
            Gio.bus_own_name_on_connection(self.conn, name, Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
                                           self.on_acquired, self.on_lost)
        self.loop.run()
        try:
            self.conn.close_sync(None)
        except GLib.Error:
            pass
        return self.exit_code


def main():
    if len(sys.argv) > 1:
        sys.stdout.write(__doc__)
        return 0 if sys.argv[1] in ("-h", "--help") else 2
    addr = private_bus_address()
    fixdir = os.environ.get("CARDWIRE_STUB_FIXTURES") or os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fixtures", "silicon"))
    init = load_initial(fixdir)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    refuse_a_real_daemon(conn)
    return Stub(conn, init, os.environ.get("CARDWIRE_STUB_LOG")).run()


if __name__ == "__main__":
    sys.exit(main())
