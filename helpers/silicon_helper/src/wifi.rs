//! `wifi-powersave <iface> on|off`: the one thing the helper does that is not about power limits and
//! firmware knobs. The shell asks it to switch a wireless interface's power save off while sound flows
//! to an AirPlay speaker (the radio sleeping between beacons drops packets) and back on after.
//!
//! What it checks before anything runs: the name is a plain interface name (it becomes an argument of a
//! program run as root), the interface exists under the sysfs root, and it is a WIRELESS one (a
//! `wireless/` directory or a `phy80211` link). The program is `/usr/bin/iw`, by absolute path (platform.rs
//! owns the list); the answer is what `iw ... get power_save` reads afterwards, never what was asked.

use std::path::Path;

use crate::ctx::Ctx;

/// A plain interface name: what the kernel allows is any byte but `/` and whitespace, and a name starting with
/// `-` would be an option to `iw`. Letters, digits, `.`, `_` and `-` (not first), at most 15 bytes (IFNAMSIZ - 1).
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 15
        && !name.starts_with('-')
        && name != "."
        && name != ".."
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn is_wireless(dir: &Path) -> bool {
    dir.join("wireless").is_dir() || dir.join("phy80211").exists()
}

/// Set the interface's power save and return what it reads back (`true` = on). `Err((exit code, why))`.
pub fn set_power_save(ctx: &Ctx, iface: &str, on: bool) -> Result<bool, (i32, String)> {
    if !valid_name(iface) {
        return Err((2, format!("'{iface}' is not an interface name")));
    }
    let dir = ctx.roots.sys_path("class/net").join(iface);
    if !dir.exists() {
        return Err((2, format!("{iface} is not a network interface here")));
    }
    if !is_wireless(&dir) {
        return Err((2, format!("{iface} is not a wireless interface")));
    }
    let now = ctx.platform.wifi_power_save(iface, on).map_err(|why| (1, why))?;
    if now != on {
        return Err((1, format!("{iface} reads power save {} after it was set {}", word(now), word(on))));
    }
    Ok(now)
}

fn word(on: bool) -> &'static str {
    if on {
        "on"
    } else {
        "off"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_that_could_be_an_option_a_path_or_a_second_argument_are_refused() {
        for ok in ["wlp47s0", "wlan0", "wl-1", "a.b_c"] {
            assert!(valid_name(ok), "{ok}");
        }
        for bad in
            ["", "-h", "--version", "wl 0", "wl/0", "../x", "..", ".", "wl;reboot", "wlan0\n", "ä", "abcdefghijklmnop"]
        {
            assert!(!valid_name(bad), "{bad:?}");
        }
    }
}
