//! `wifi-powersave` and `capabilities`: what the helper accepts, what it refuses before anything would run, and that in test
//! mode nothing is executed (the simulated platform answers; `iw` is never started here).

mod common;
use common::*;

fn with_wlan(sb: &Sandbox) {
    sb.put(&sb.sys("class/net/wlp47s0/wireless/.keep"), "");
    sb.put(&sb.sys("class/net/wlp47s0/address"), "aa:bb:cc:dd:ee:ff\n");
    sb.put(&sb.sys("class/net/enp3s0/address"), "aa:bb:cc:dd:ee:00\n");
    sb.put(&sb.sys("class/net/wlan9/phy80211/.keep"), "");
}

#[test]
fn a_wireless_interface_is_set_and_read_back() {
    let sb = Sandbox::new("n6506mv_618lts");
    with_wlan(&sb);
    let r = sb.run(&["wifi-powersave", "wlp47s0", "off"]);
    r.expect(0);
    assert!(r.ok());
    assert_eq!(r.json.keys(), ["ok", "proto", "wifi"]);
    assert_eq!(r.json.at("wifi.iface").str(), "wlp47s0");
    assert_eq!(r.json.at("wifi.powerSave").str(), "off");
    let r = sb.run(&["wifi-powersave", "wlp47s0", "on"]);
    r.expect(0);
    assert_eq!(r.json.at("wifi.powerSave").str(), "on");
    // a phy80211 link is a wireless interface too
    sb.run(&["wifi-powersave", "wlan9", "off"]).expect(0);
}

#[test]
fn a_name_that_is_no_wireless_interface_is_refused_before_anything_runs() {
    let sb = Sandbox::new("n6506mv_618lts");
    with_wlan(&sb);
    let before = sb.snapshot();
    for (iface, why) in [
        ("enp3s0", "not a wireless interface"),
        ("wlnone", "not a network interface"),
        ("-h", "not an interface name"),
        ("--version", "unknown option"),
        ("../class/net/wlp47s0", "not an interface name"),
        ("wl0;reboot", "not an interface name"),
        ("", "not an interface name"),
    ] {
        let r = sb.run(&["wifi-powersave", iface, "off"]);
        r.expect(2);
        assert!(!r.ok(), "{iface}");
        assert!(r.why().contains(why), "{iface}: {}", r.why());
    }
    for args in [
        vec!["wifi-powersave"],
        vec!["wifi-powersave", "wlp47s0"],
        vec!["wifi-powersave", "wlp47s0", "maybe"],
        vec!["wifi-powersave", "wlp47s0", "on", "extra"],
    ] {
        sb.run(&args).expect(2);
    }
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn a_plain_user_cannot_write_and_says_so() {
    let sb = Sandbox::new("n6506mv_618lts");
    with_wlan(&sb);
    let r = sb.run_raw(&["wifi-powersave", "wlp47s0", "off"], &[]);
    r.expect(2);
    assert!(r.why().contains("pkexec"), "{}", r.why());
}

#[test]
fn capabilities_lists_the_verbs_for_anyone_with_nothing_read() {
    let sb = Sandbox::new("n6506mv_618lts");
    let r = sb.run_raw(&["capabilities"], &[]);
    r.expect(0);
    assert_eq!(r.json.keys(), ["ok", "proto", "verbs"]);
    let verbs = r.json.at("verbs").strs();
    for v in ["status", "apply", "mux-request", "wifi-powersave", "capabilities"] {
        assert!(verbs.contains(&v), "{v} in {verbs:?}");
    }
    // an older build said "unknown command" to the verb itself: that is how a caller tells one without `capabilities`
    let r = sb.run_raw(&["nonesuch"], &[]);
    r.expect(2);
    assert!(r.why().contains("unknown command"));
}
