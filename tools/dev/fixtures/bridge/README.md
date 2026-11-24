# Fixtures of the bridge tool: SYNTHETIC

Every file here was written by hand from the documented format of the program that produces it. No phone was plugged in when they
were made, so none of them is a capture. The user will run a capture script later and these files will be replaced by real bytes;
until then they prove the parsers on the format as documented, nothing more.

| File | Format | Parser |
|---|---|---|
| adb_devices_l.txt | `adb devices -l` (usb, tcp, mDNS serial, unauthorized, offline, no permissions) | `parse.parse_devices_l` |
| adb_track_wire.bin | the smart socket after `host:track-devices-l`: `OKAY` + frames (one phone, an empty list, two transports) | `parse.FrameParser` |
| adb_mdns_services.txt | `adb mdns services` | `parse.parse_mdns` |
| adb_push_progress.raw | `adb push` on a tty: `\r` redraws and the final summary | `parse.split_redraws`, `parse.parse_push_line` |
| dumpsys_battery.txt | `adb shell dumpsys battery` (level, temperature in tenths of a degree, health code) | `parse.parse_dumpsys_battery` |
| df_data.txt | `adb shell df -k /data` (toybox) | `parse.parse_df` |
| facts_blob.txt | the answer of `parse.FACTS_SCRIPT` | `parse.parse_facts_blob` |
| facts_blob_usb_mtp.txt, facts_blob_usb_none.txt | facts_blob.txt with the `==usb` section of the facts script (`dumpsys usb | grep screen_unlocked_functions`): the line the phone prints with Default USB configuration = File transfer, and the empty answer | `parse.parse_facts_blob` (`usbUnlocked`) |
| ident_blob.txt | the answer of `parse.IDENT_SCRIPT`: the `ip -o -4 addr show` part in the format the user's phone printed (capture 2026-11-18, addresses replaced), the name line as Android documents it (`settings get global device_name`; not captured) | `parse.parse_ident` |
| lockstate_*.txt | the answer of `parse.LOCK_SCRIPT` (grep'd dumpsys trust / window / power / deviceidle): locked and dozing (the line shapes captured on the user's Android 16 phone, 2026-11-19, the app name replaced by com.example.app), unlocked and awake, locked with an app window on top, trust saying nothing | `parse.parse_lockstate` |
| mountinfo.txt | /proc/self/mountinfo (an sshfs mount, an aft-mtp-mount, a path with a space) | `parse.parse_mountinfo` |
| scrcpy_version.txt | `scrcpy --version` | `parse.parse_scrcpy_version` |
| scrcpy_noadb.txt | scrcpy's stderr when no device is found | `parse.last_error_line` |

Unverified until a real capture: adb's exact wording for each state, `no permissions` lines, the mDNS instance naming, what
`aft-mtp-mount` prints and whether it stays in the foreground, scrcpy's "ready" lines.
