# Bridge (the phone)

## What it is

The bridge between the laptop and an Android phone: what KDE Connect knows of the phone (battery, signal, whether it is in reach),
its screen mirrored and controlled from the laptop (scrcpy), its storage mounted (by cable or over Wi-Fi), files sent to it, the
clipboard, a ring to find it, a screenshot of it. The popup is the phone itself: its screen is the control panel, and it turns
over to show its back, which is the phone's own back and nothing more. Contract: [contracts/bridge.md](contracts/bridge.md).

## Where it lives

- A DRAWBRIDGE on the right island, after the network pill (`bridge` in `shell.jsonc`'s `zones`; the user's idea, 2026-11-21:
  the icon font's bridge, the left tower this computer, the right one the phone). Its shape is the state: no phone around, both
  leaves stand raised and bare, faint: four strokes, a tower and its leaf, a leaf and its tower (the cable and its suspenders fold
  down onto a leaf as it comes up; kept as a chain they melted into each other at the bar's size); the phone in reach, the bridge is down in the plain bar ink, over Wi-Fi and on the
  cable alike (connected is the usual state and takes no colour); a phone that asks to pair lowers its own leaf alone, in the
  warn hue. What happens crosses it as CARS, one dot each, driving the way the data goes: a convoy to the phone for a file send,
  one car for the clipboard (to the phone) or a screenshot (from it), one at a time in the accent for as long as a cast or a
  mirror runs (also with the popup closed), one parked at the phone's tower while its storage is mounted; a failure is a red car
  that stops at mid span and backs off; ringing the phone throws two waves off its tower. The leaves come down and bounce on the
  pier when the phone arrives, and lift past their stop and settle when it goes; the cable going in makes the deck sag once. Under
  the pointer (and in the OLED care's random turns) the bridge salutes: down, the leaves swing up about a quarter turn, drop and
  bounce twice on the pier; raised, they dip and bounce off their stop (round 6b's small lift was "barely visible"). A cast's car moves one device
  pixel a step, so an hour of casting costs a repaint every ~155 ms and nothing at rest.
- A click opens the popup under it. A file dropped on the glyph is sent to the phone and opens the popup.
- Phones and tablets only: the computers KDE Connect knows (desktops, laptops) are left out of the device menu and of pairing.
- No key, no IPC verb.

## What you can do

**The front: the phone's screen.** A status bar with the phone's real cellular bars and network type, how it is linked (USB, Wi-Fi)
and its battery; the phone's name (a click lists the paired phones when there are several) and one line saying what is going on;
six tiles:

| Tile | Does | Needs |
|---|---|---|
| **Mirror** | opens its page: the mode, four icons named by their tips (Mirror = the phone's screen ON the phone's display, below; Desktop = a second, virtual screen of the phone's, also on the display, the phone's own screen stays free; Camera and Audio in scrcpy's window), Screen off, Record (a Mirror or Desktop cast records too: the same cast in the popup, the same unlock and hold, `lares-cast` writing the file into `mirror.recordDir`, and a toast at its end says where it went; Camera and Audio record in scrcpy's window), then Start / Stop. While the cast runs the tile is lit and goes straight back to it | adb (cable, or Wi-Fi: below) and scrcpy |
| **Files** | opens its page: the storage by **Cable** (MTP, at `files.usbMount`) and over **Wi-Fi** (KDE Connect's sftp): Mount, Open (in your file manager), Unmount; the path is a link that copies itself. Over Wi-Fi the mount is the phone's whole tree as its sftp server shows it (an ordinary app on Android may read much of `/`: no root is involved); Open and the path go to the phone's own storage inside it (`<mount>/storage/emulated/0`, KDE Connect's `getDirectories`) | cable: `android-file-transfer`; Wi-Fi: `sshfs` |
| **Send** | picks files (the portal's chooser) and sends them: by cable `adb push` into `files.sendDir` with a progress toast, else through KDE Connect | adb, or the phone in reach |
| **Clipboard** | sends the clipboard to the phone | the phone in reach |
| **Ring** | rings the phone (find my phone): loud, so never by accident -- a click arms the tile ("Hold", 4 s), a press held 1.2 s while armed rings | the phone in reach |
| **Shot** | a screenshot of the phone into `shots.dir`, shown as the screenshot card | adb |

A tile that cannot act right now is faint and says why under the pointer ("Out of reach. Same Wi-Fi as this computer"). A try
that FAILED takes nothing away: the tile, the button, the row stay pressable and say why the last try failed, and a press tries
again (round 2 of the functional review: a busy unmount left the Files row with no button, a failed Wi-Fi shot left the tile dead).
Those words are the tool's; the popup decides nothing.

**The cast.** Mirror and Desktop run on the phone's own display (Desktop: a new virtual screen of the phone's made at the display's
shape, `lares-cast --new-display --flex`; when the cast ends its apps move to the phone's own screen, never closed): the page grows out of the Mirror tile and fills the display (the phone
brings its own status bar). The pointer is a finger, the wheel scrolls, the keys type; **Left, Down and Right are Back, Home and
Recents** (the user's call: three keys in a row, as Android's buttons stand; they never reach the phone as arrows). While it shows,
the popup's free edges RESIZE the phone like the notes popup's (the phone keeps its shape and is drawn again at its new size), about
its centre: a resize never moves the popup. The middle of the foot, under the phone, MOVES it along the bar (an open hand; the user's
review: a corner drag had walked it to the centre island). A reset button at the top right takes it back to its resting size and
place. A resized Mirror restarts its stream at the new size (`cast.reloadOnResize`, on by default): the last frame is held, blurred,
under a "Resizing" box until the new stream's first frame. A Desktop is never restarted (its apps would go): its virtual screen is
RESIZED with the popup (scrcpy's flex display), its density kept. It is laptop-sized (the user's call, round 6): about one laptop pixel
per Android dp (`cast.desktopScale`), never narrower than 320 dp (`cast.desktopMinDp`), and at least 640 px on its short side
(`cast.desktopMinPx`): the phone's own secondary launcher (the teal button and its app list, ZTE's) lays out in PIXELS whatever the
density, and under ~600 px its icons overlapped ("melt into each other"). Smart Launcher cannot run there: started on a second
display, a launcher that is the phone's home takes the phone's one home task with it. A Desktop runs while the phone stays LOCKED
(Android keeps a new display usable; the lock screen is the phone's own screen's), so it never unlocks the phone: not at its start,
not on a click, not when the popup opens over it.
The size goes back WITH the page (a swipe back scrubs it with the fingers).
Three icons above the phone, in the stage's own margin (never over the picture): Sound (the phone's sound on this computer, per
phone), Window (into scrcpy's own window) and Stop. LATENCY: without sound every frame is shown as it is decoded (~12 ms past the
phone's own on the fake phone); with Sound on the picture keeps the phone's timestamps to stay in step with the sound, and Qt's
player then buffers it (~0.45 s). A player that shows nothing for 3 s while the phone sends pictures (or reports an error) is opened
again by itself (`CASTVIEW reopen` in the shell's log). A cast that ENDS by itself (the phone closed the stream: Wi-Fi, an adb restart)
comes back by itself: the last frame held blurred under "Reconnecting", up to four tries (0.5, 1, 2, 4 s), then the reason and Try
again; it never stands at "Starting" (round 5 did, after every lock and unlock: below, "The USB mode"). While the phone's screen is
dark the page says "Screen off": a click or a key wakes it, and unlocks it when a PIN is kept ("Unlock"). Escape or a sideways swipe goes back to the
controls and the cast goes on; the Mirror tile comes back to it. Closed, the popup keeps the cast for `cast.closeAfterS` (120 s),
then it stops. The bar's bridge shows a running cast as cars in the accent, crossing from the phone.

Files can also be **dropped** on the phone. With no phone paired the screen is the pairing page (phones KDE Connect sees, their
key, Pair / Accept / Reject); with a paired phone out of reach the screen is asleep (last seen, Look again).

**The body.** The power key wakes or sleeps the phone's screen and the volume rocker changes its volume (both through adb); the
cable in the port is drawn while the phone is wired, and a click on it opens Files. The triggers, the red key, the vents, the jack
and the lenses are drawn and do nothing.

**Details.** The device's name opens the device menu: the other devices, **Details** and Pair another. The Details page is the
device's sheet: the model, Android's version, storage, the battery's health and temperature (when adb is up), the address, the
KDE Connect key; **Keep wireless ready**; **Wireless debugging** (Pair: a QR code); **Unlock PIN** (below); **File transfer at unlock**
(below, "The USB mode"); Unpair (asks twice); and what is missing on
this machine, each with its fix. (It was the
phone's back face until the user's review of round 2: the back is only the back now.)

**Unlock.** The user's decision (2026-11-19): the phone's PIN is kept in the login keyring (Details, Unlock PIN: Set / Change /
Forget; a masked field, digits and letters, 4 to 16) and typed over adb into the phone's lock screen. ONLY FOR A CAST (the user,
2026-11-21: "it should only unlock when I request casting"; mounting and browsing the files work with the screen dark): opening the
popup wakes nothing (round 5 unlocked at every open). adb's own key (the one the phone trusts by "Always allow") is the trusted link; Android lets no key stand in
for the PIN on an unrooted phone (its one keyless way, Smart Lock's trusted devices over Bluetooth, needs a held Bluetooth link and
never covers the first unlock after a restart). The tool (`lares-bridge unlock`) wakes the phone, brings up the PIN pad, and types
ONLY when the lock screen has the keys on an awake phone; a PIN that fails is never typed again until it is set again (Android
throttles wrong tries); a locked keyring is never opened (no prompt from a popup); the PIN is on a pipe only (never argv, a file,
the trace, `calls` or an answer). The black picture of the PIN pad in a cast is Android blanking captures of it (FLAG_SECURE): the
keys still reach it. A failed PIN, or a lock screen that would not take the keys, is one toast.
Round 6 (the user's goal: use the phone lying upstairs from downstairs): the wake, swipe and PIN run before every Mirror's start
(`castprep --unlock`; a reconnect never types it) and at the first click or key on the picture of a dark or locked phone (that click or key is not
sent; the page holds the lock screen's picture under "Unlocking" and sends the phone nothing until the answer). A phone that locks or
times out while nobody touches the picture stays as it is. A lock screen that only needs a swipe (Smart Lock trusts the place) is taken
away without the PIN. With no PIN kept, a click on a locked picture reaches the phone (type the PIN by hand).

**Asleep when not cast.** A Mirror holds the phone's screen on while it runs (`castprep --hold`: the phone's own screen timeout is
recorded ONCE on this computer, in `hold.json` beside the state, and raised to 30 minutes), and its end gives it back (`castend`; a
timeout the user changed meanwhile is left alone). When the cast ends -- Stop, another phone's cast, or the popup closed for
`cast.closeAfterS` -- a phone that was dark when the cast began, or that the picture woke, is put back to sleep (`--sleep`:
KEYCODE_SLEEP, only if it is awake); Window (into scrcpy's window) leaves it lit. The shell's start gives back any hold a crash left
(`castend --all`). Why the bridge holds the screen itself: scrcpy's own `stay_awake` sets `stay_on_while_plugged_in` and puts back what
it read at its start from a cleanup process ON THE PHONE, which dies with adbd; each lock and unlock restarted adbd (the USB mode, below),
the next cast read the forced 7 as the phone's own, and the user's phone stayed on whenever it charged (found 2026-11-21, set back to 0
with their OK). A Desktop holds nothing: its screen runs with the phone dark and locked.

**The USB mode.** The phone's Developer option *Default USB configuration* was File transfer. Android then switches its USB functions at
EVERY lock (charging only) and unlock (File transfer), cable in or not, and each switch restarts adbd: every adb link dropped for ~0.3 s,
Wi-Fi included, and every cast with it (14 drops in the user's test, read from the phone's own log; round 5's "Starting for ever"). The
user's call (round 6): the bridge switches it to No data transfer itself (`usbcalm`, asked at a popup open when the facts say File
transfer) and Details shows "File transfer at unlock" with the way back. A cable mount then asks the phone for File transfer itself
(`svc usb setFunctions mtp`).

**The back.** Two fingers sideways turn the phone (the turn follows the fingers; a lift past a third goes on, a shorter one
springs back). The back carries nothing to read or click: the turn is a thing to play with.

**The turn.** One whole turn plays as the popup opens (`flip.onOpen`). Escape goes back from a page, then closes.

**Free look.** With the pointer over the popup, hold **Alt** and move the pointer (nothing pressed): the phone turns with the
hand, every way round -- sideways about its own long axis as far as you like, up and down a quarter turn each way (its head's
wall, its foot's), never rolled. The phone lifts off a little and a glint runs across its glass as the key goes down; that is
the "ready". The pointer is hidden meanwhile and kept where it was (Hyprland puts it back as it strays, so it never leaves the
popup), and it reappears there when Alt is let go, as the phone goes back to the face it showed (the short way round). It works
on every page, the cast included; nothing on the screen can be clicked meanwhile. The cast plays on behind the turned phone (its
player is not opened again, no "Starting", and a new size asked for meanwhile waits until the phone has landed). Two things that follow from how Wayland works:
a surface hears modifier keys only while it holds the keyboard, so once the pointer has MOVED onto the popup the popup takes the
keyboard (the window you were typing in gets it back when the popup closes or you click that window); and Alt is still the first
half of your Alt binds, so Alt+Space over the popup starts a look for the instant before the launcher opens. The shadow on the popup is the
phone's own silhouette as a light a little above you throws it, in every pose: an edge turned towards you throws its shadow further,
and the lifted phone's shadow falls away, softer and fainter (`shadowHeight` beside the offset and softness; until 2026-11-21 it was an
upright box made for the flip, which stood out round a tilted phone like a card behind it).

## Mirroring over Wi-Fi, and the address that changes

Nothing stores the phone's address. Every start resolves the way to the phone afresh: the cable if it is plugged, else an adb
connection over the network that is already up, else what adb's own discovery lists (Android's *Wireless debugging*), else the
address KDE Connect reports for the phone right now with the armed port. So a new address from the router changes nothing.

The user's goal (2026-11-19): the phone ready for Wi-Fi at all times, primed as little as possible. What makes it so:
- **Keep wireless ready** (the Details page, per phone, ON by default): each plug-in arms `adb tcpip 5555`, which lasts until the
  phone restarts, on any network. adb then listens on the LAN, guarded by adb's key (this laptop's, authorised on the phone),
  not encrypted. A phone that already listens is left alone: arming restarts adb on the phone, which re-enumerates it on the bus
  -- a new plug-in to the watcher -- and arming that again looped for ever (2026-11-19).
- **Wireless debugging, paired once** (Details, Pair: scan the QR code with the phone's Developer options > Wireless debugging >
  Pair device with QR code): encrypted, found by mDNS on any network (adb joins it by itself; the bridge knows it by the phone's
  serial). Once paired, each plug-in also switches it on. After a RESTART, with no cable: one tap on the phone's Wireless debugging
  quick tile (Developer options > Quick settings developer tiles) is all it takes.
- The wall: a phone that restarted, with neither the cable nor that tile, has no adb on the network; Android allows nothing more
  without root. And a network that keeps its clients apart (eduroam) carries neither KDE Connect nor adb.
- On the phone, once: Developer options > **Disable adb authorization timeout** (else Android forgets this laptop's key after 7
  days without a connection), and the Wireless debugging quick tile.

## One phone, three names

KDE Connect, adb and the USB bus each name the phone their own way (this one: "REDMAGIC 10 Pro", the name the phone gives itself;
"NX789J"; "REDMAGIC 10S Pro"), so a name is no proof that two of them see the same phone. When a phone comes onto the cable with
adb up and no stored link, the watcher asks it once, over the cable, for its addresses and its own device name; the KDE Connect
phone reached on one of those addresses (or, failing that, the only one with that name) is it. The link (KDE Connect id -> USB
serial) is stored, never the address, and from then on the cable alone is enough. What was kept under the cable-only key
(`adb:<serial>`: the mirror mode, Keep wireless ready, the facts) moves to the phone's own key.

## Mounting: what was chosen and why

- **By cable: `aft-mtp-mount`** (android-file-transfer) at `files.usbMount`, `/mnt/android` as before. It is installed, has its own
  MTP stack and reads and writes parts of a file. The other FUSE mounts (mtpfs, simple-mtpfs, jmtpfs: libmtp) copy a whole file
  for every read; go-mtpfs is an AUR git build; gvfs-mtp gives GIO addresses, not a path a terminal file manager opens; adbfs runs
  a shell command per operation. The Arch Wiki notes aft's FUSE is 7 to 8 times slower than its own CLI, so **bulk sending does not
  go through the mount**: Send uses `adb push`.
- **Over Wi-Fi: KDE Connect's sftp**, which needs `sshfs` (it was missing: that is why KDE Connect's own browse failed).
- A mount left behind by an unplug is cleaned up when the bridge made it; one made by hand is offered as "Clean up".
- When the phone's USB mode is not File transfer and adb is authorised, Mount asks the phone to switch (`svc usb setFunctions
  mtp`); otherwise it says to choose File transfer on the phone.

## Settings

`config/bridge.jsonc` (every key optional; `.examples/bridge.jsonc` has each at its default with what it does):

| Key | Default | |
|---|---|---|
| `files.usbMount` | `/mnt/android` | where the cable's mount goes (a directory you own) |
| `files.open` | `kitty ... yazi {path}` | the file manager, as an argv; `{path}` is the mount point, filled in where it stands, or added at the end when the list has none (never `xdg-open`: it opens folders in easytag here) |
| `files.pickDir` | `~` | where Send's file chooser starts |
| `files.sendDir` | `/sdcard/Download` | where a cable send lands on the phone |
| `mirror.usb`, `mirror.wifi` | no limits; 1600 px, 6M, 60 fps | scrcpy's size, bit rate and frame rate per link |
| `mirror.recordDir`, `mirror.extraArgs` | `~/Videos`, none | where Record writes (scrcpy's window and the popup's cast alike); anything else for scrcpy |
| `adb.start` | `onDemand` | when the adb server may be started: for a need only, or also at every plug-in (`onPlug`) |
| `adb.idleKillS`, `adb.port` | 300, 5555 | a server the bridge started is stopped this long after its last need; the armed port |
| `shots.dir` | `~/Pictures/Screenshots` | |
| `flip.onOpen` | true | the turn as the popup opens |
| `cast.closeAfterS` | 120 | the popup's cast keeps running this long after the popup closes |
| `cast.reloadOnResize` | true | a resized Mirror restarts its stream at the new size (sharper) |
| `cast.desktopScale` | 1.0 | a Desktop's laptop px per Android dp (0.5 - 3): larger = bigger text and icons |
| `cast.desktopMinDp`, `cast.desktopMinPx` | 320, 640 | a Desktop's short side is never fewer dp (apps), nor fewer pixels (the phone's secondary launcher lays out in px) |
| `cast.unlock` | `start+touch` | when the kept PIN unlocks a locked phone: as a Mirror starts, at the first touch of a locked picture, both, or `never` |
| `cast.keys` | `Left`, `Down`, `Right` | the keys that are the phone's Back, Home and Recents (Qt's key names; `""`: none, and the arrow goes to the phone as an arrow) |
| `cast.sleepAtEnd` | true | a phone the cast lit goes back to sleep when the cast ends |
| `cast.holdMin` | 30 | how long a Mirror's hold keeps the phone's screen on without a touch (its screen timeout while the cast runs), minutes |
| `relight` | true | the light on the glass follows the pointer |
| `lookKey` | `alt` | the key held for the free look: `alt`, `ctrl`, `shift`, or `off` |
| `devices.<name or key>` | | `skin` (`redmagic-10s-pro-moonlight`, `generic`), `hidden` |

The look (the phone's size, the camera, the turn's times, the lamps, the screen's paddings and tiles) is tuned in
`mockups/bridge.qml`; Save writes the module (`PhoneStage`, `BodyLayer`, `BridgeStyle`). The popup's own ratio is
`scale.popups.bridge` in `shell.jsonc`.

## On this machine: your steps

1. `sudo pacman -S sshfs` for the storage over Wi-Fi.
2. On the phone: Developer options, **USB debugging** on; plug it in and allow this laptop (once). Needed for Mirror, Shot, the
   keys, a cable Send.
3. Optional: `kdeconnect-indicator` can leave the Hyprland autostart; the bridge shows the same and the daemon starts by itself
   when asked (the bridge never starts it: with no daemon on the bus the pairing page says so).
4. `lares setup` lists what is missing (the rows of `tools/bridge/lares-bridge doctor`).
5. **Once, for the parsers:** with the phone plugged in, `tools/dev/bridge_capture.sh` (then `--wireless` unplugged; `--with-push`
   and `--with-mount` for the progress and the mount). It records what this phone and this adb really print into
   `~/.cache/lares/bridge/` (never the repo: it holds the serial and addresses). Until then the tool reads the documented formats
   and the fixtures are marked synthetic.

## How it is built

| Path | Role |
|---|---|
| `tools/bridge/lares-cast`, `castlib/`, `modules/bridge/cast/` | THE CAST: our own client of scrcpy's phone-side server (the jar scrcpy ships), its H.264 (+ AAC) as FLV on a local port that a low-latency MediaPlayer plays (CastView); touches, scrolls, keys and text back over scrcpy's control socket. CastSession (one per shell, in the service) owns the process; CastPage (`screen/`) is its page |
| `tools/bridge/lares-bridge`, `bridgelib/` | THE TOOL (Python + Gio): `watch` (one event loop: KDE Connect's signals, USB hotplug, the mount table, adb's own device feed while a server is wanted, job records; no fork and no poll at rest; one JSON line per change) and the one-shots (`mirror`, `stop`, `mount`, `send`, `shot`, `ring`, ...). The pure rules: the merge of a device across KDE Connect / adb / USB, the transport ladder, every argv, and `can` (each action's verdict with its reason and hint) |
| `modules/bridge/data/BridgeService.qml` | ONE per shell: reads `watch`, keeps the model, runs the one-shots, posts the toasts (a send: one live progress toast, replaced by one closing toast). Not live it starts nothing and plays `BridgeScenarios.js` through the same parser |
| `modules/bridge/data/BridgeModel.js`, `BridgeConfig.qml`, `ActionRunner.qml` | the line's parser (total) and the words; the config; the one-shot queue |
| `modules/bridge/BridgePopup.qml`, `BridgeStyle.qml` | the popup: the stage, the swipe (one reader: a page's back, else the phone's turn), Escape, the drop |
| `modules/bridge/screen/` | the front face: `ScreenFace` (which screen; the tile-to-page morph), `StatusBar`, `MirrorPage`, `FilesPage`, `PairingScreen`, `AsleepScreen`, `DeviceMenu` |
| `modules/bridge/screen/DevicePage.qml`, `DeviceSheet.qml`, `SheetRow.qml` | the Details page: the device's sheet and the rare controls |
| `modules/bridge/body/PhoneStage.qml` | the phone: its two faces, its turn, its keys' zones, the device grid |
| `modules/bridge/body/BodyLayer.qml`, `shaders/bridge_body.frag` + `.vert` | the body, traced per pixel from one quad: the slab with its rounded edge, what stands proud of the frame, glass both sides, the decor under the back glass, the frame's walls, the shadow; the display is a hole |
| `modules/bridge/body/BodyGeometry.js` | the phones in millimetres (`SKINS`: the outline, the display, the back's parts, what each wall carries, the keys) and the camera; the shader, the stage and the decor's generator all read it |
| `modules/bridge/body/CableStub.qml` | the cable in the port |
| `tools/bridge/decor_paths.json` | the chip badge's outlines (the maker's flame and word, as a stencil; see the portrait) |
| `tools/bridge/make_decor.py`, `modules/bridge/assets/` | what the body is dressed in, drawn by our own code into seven textures per skin: under the back glass the colour, the relief and depth, the grooves' direction, the roughness / glow / metal, and the printed film's mask (whose shadow on the lined plate the shader throws away from the light; its green says where a back is bare metal with no glass over it); the frame's four walls as one atlas (colour; relief and roughness). `--check` says whether they are current, `--preview <dir>` writes a flat look at them |
| `modules/bridge/BridgeBarButton.qml`, `bar/BridgePose.js`, `bar/BridgeTraffic.js`, `bar/BridgeParts.js` (generated) | the bar glyph: the drawbridge's leaves, the cars, the salute |
| `modules/bridge/BridgeBarOwner.qml` | the bar-side owner |
| `modules/common/components/TileButton.qml` | shared: a raised tile with a glyph and a label |

**How the phone is drawn.** At rest the face turned to the viewer lies in the camera's own plane, where a pixel is a pixel: its
QML items are drawn as any popup's, untransformed, under (front) or over (back) the body, and the body is a cached picture; no
clock runs. While the phone turns the faces are the same items under the glass's projection (`BodyGeometry.faceMatrix`) and the
body is traced live. Nothing is captured into a texture. A frame of the turn costs about 1 ms on the Intel GPU at scale 1.25; the
shader compiles in about 0.3 s.

**The portrait** (`redmagic-10s-pro-moonlight`) is the user's own phone, MEASURED off their photos (`feedback/phone_photos/`,
git-ignored: the top-down back rectified to millimetres, the four sides, the front) and then drawn by `make_decor.py` from those
numbers; no pixel of a photo is in the repo (the one thing not ours is the chip maker's flame and word on the duct's badge: its
published mark as a stencil, by the user's call, stored as outlines in `tools/bridge/decor_paths.json`). Under the back glass: the
mirror border with its two tabs, the two camera boxes, the knurled sheet (it dips under the border at the head and the right, where
its points give out), the blue pane lying flush IN that sheet with a hair's gap round it, on it the lamp, the macro camera and the X
(a striped field flush with the pane, its outline one more of its own light lines; a window sunk into it, ring within ring; the
emblem), the brushed duct with the fan and the chip's badge (a roughened square: the flame and the letters are the duct's own
metal left alone), the lined plate (its lines turn at the seam) with what is printed on it -- a thin silvery film the lines show
through: the line art, the wordmark, the pill over the two foot screws, the mark -- and seventeen screws down in their wells. On
the frame: the triggers, the antenna's lines, both vents (a slim centre piece on four lower bridges), the rocker, the round power
key, the red slider, every hole. How it is lit:
- a GROOVED surface (the brushed duct, the turned fan hub, the ruled plates) has a direction, and its light is the mean of its
  two flanks': a lamp smears across the grooves, and the plate's two halves take different sheens. The ruled lines themselves (the
  plate's, the window's rings, the field's stripes) are drawn as a wave across them: its valley is the dark line, its two slopes
  the two flanks, and flank A is always the one leaning the way the wave runs (a direction alone has no "which side"). Where a
  pixel cannot hold the lines they are drawn coarser -- every other one, then every fourth, each passing into the next -- and only
  past that is the sheen all that is left. The rings keep round corners to the middle (`ringTurn`: a ring's corner gives up only
  that share of each inward step);
- the knurled sheet's ground is bare metal and its points are matte: seen straight on under the light it is pale and the points
  barely stand out, seen from the side it darkens and they do;
- black metal turned in fine rings (a lens's bezel, the fan's housing) is flat and takes a faint pair of spokes; a lens's wide
  shoulder is matte black and gives almost nothing back;
- mirror metal (the border, the flash's ring) sees a room whose viewer's side is the dimmer one, so a flat mirror runs from light
  to dark and changes as the phone turns;
- two tall lights stand to the viewer's sides, out of every mirror's sight at rest: a face turning past one catches it as a band
  that runs across the glass, as the phone leaves its rest and as it comes home;
- a part with no bevel of its own (the mirror border, the rings round the lamp and the macro camera, a screw's well) keeps its
  depth and its shade but has no slope, so its edge catches no light; and where the relief turns within a pixel the surface is
  written rougher, so a mirror edge never flashes single pixels as the phone moves;
- a main lens's bright collar lies under the glass's black print: hidden from straight above, found only by looking in from the
  side, on the side nearer the eye;
- the light the pointer leads does not jump to a pointer that comes in at another side: it sets off after it slowly and gathers
  speed until it has caught it (`relightCatchMs`, `relightJump`).

**What happened, afterwards.** `~/.cache/lares/bridge/trace.jsonl` holds every line the watcher printed, every one-shot with its
answer and every command it ran with its status and output's tail; `~/.cache/lares/bridge/jobs/` the whole output of each mirror,
mount and send. Read them after a test on the real phone: they are the ground truth, and they stay out of the repo.

**A job outlives the shell.** A mirror, a cable mount and a cable send run under a wrapper in a systemd scope; their state is read
from a record, so a popup closed or a shell restarted mid-mirror still shows it and can stop it.

## Limits

- Android only, through KDE Connect and adb. iPhones are not bridged.
- Mirror, Shot and the keys need adb; after a phone restart adb over the network is off until it is armed again (above).
- KDE Connect reports nothing back for a file it was handed: a Wi-Fi send's toast says "handed over", not "arrived".
- KDE Connect's sftp shows only the folders the phone's KDE Connect app was allowed.
- The portrait is the REDMAGIC 10S Pro in silver; any other phone gets the `generic` body: an iPhone 18 Pro in Glacier (the
  user's pick, 2026-11-21) drawn from the maker's published sizes, with no maker's mark, whose camera plateau and three lenses
  really stand out of the back (`back.plateau`, `back.lenses`, `ringH`: geometry in the body's shader, not paint; their heights
  are a forum's caliper figures). A new portrait is a `SKINS` entry in `BodyGeometry.js` and a drawing in
  `tools/bridge/make_decor.py`.
- The name on the screen is the phone's OWN (what KDE Connect reports; Android: Settings, About phone, Device name). This phone
  calls itself "REDMAGIC 10 Pro" until it is renamed there; the portrait is chosen by that name or by `devices.<name>.skin`.
- A phone's serial, addresses and KDE Connect id are never written into the repo; the state file holds links between ids, never
  an address.

## How to change it

- The look: `mockups/bridge.qml` (`quickshell -p mockups/bridge.qml`), change on the panel, Save.
- The phone's proportions, what is on its back and on its frame: `BodyGeometry.js` `SKINS` (millimetres) for where things are,
  `tools/bridge/make_decor.py` for how each is drawn (run it: it rewrites `modules/bridge/assets/`), and
  `tools/dev/bake_shaders.sh` after a change to the shader.
- A pose sheet to look at: `tools/dev/bridge_body_sheet.sh` (`POSES=`, `MODE=dark`, `SCALE=1.25`, `SKIN=generic`, `BUSY=1`
  lights what lights up, `CELLS_BACK=1`, `TILT=-90` the top wall, `90` the bottom one).
- Every side of the phone: the mockup's Run tab holds the pose (turns) and the tilt (degrees) (`BRIDGE_POSE=`, `BRIDGE_TILT=`
  for a render); its **Free look** switch holds the popup's own look without the key, and the Phone tab's group Free look has
  its numbers (the way for a turn, the way back, the lift, the glint).
- Free look after a change: `tools/dev/bridge_popup_probe.sh` (group M) and, for what only a compositor shows (Alt reaching a
  layer surface, the pointer put back to the pixel, the hand's way counted once), `tools/dev/bridge_look_env_probe.sh`.
- Every state of the popup as one contact sheet per mode: `tools/dev/bridge_sheet.sh [outdir]` (`STATES="home details back top"`,
  `MODES=light`, `SCALE=1`); for a before / after, run it on both trees.
- Proof:
  - the tool: `python3 tools/dev/bridge_cases.py` (the merge, the ladder, every argv, `can`, the parsers; ARMs `storedip`,
    `nousbfirst`, `weakmerge`) and `tools/dev/bridge_tool_probe.sh` (the real tool on a private bus with a fake KDE Connect, a
    fake adb server and PATH stubs, and the seam with the service's own parser and argv; ARMs `nopidfd`, `cleanforeign`, `noack`; round 6:
    `nodismiss`, `nocastunlock`, `nowaitunlock`, `unlockfails`, `noaskmtp`, `nocalmpref`, `grepexit`: the stub's `grep` exits 1 like the
    phone's when the line is absent, which broke facts and usbcalm on the real phone while the old stub said 0);
  - the service: `tools/dev/bridge_service_probe.sh` (ARMs `twotoasts`, `progressstays`, `seriallate`, `alwayswatch`; round 6:
    `oldended`, `noreconnect`, `reconnectpin`, `flapforever`, `usbagain`, `deskrestart`; a recording cast: `recordprep`, `recordlost`,
    `recordreload`, `recordquiet`);
  - the cast: `tools/dev/bridge_cast_probe.sh` (the real lares-cast on a fake phone, and the whole popup over it: a free look, a
    resize and a lost stream during one, the opening turn; ARMs `turnstops`, `lookresize`, `hiddenhold`, `altwakes`; round 6 ARMs
    `heldleaks`, `keysmix`, `touchnounlock`, `bareprobe`) and `python3 tools/dev/bridge_cast_cases.py` (round 6 ARMs `goingaway`, `anydisplay`, `oldevents`,
    `locknoanswer`, `resizebytes`, `flexalways`, `nowake`, `resizenoflex`, `nobackoff`, `nopdeathsig`, `sysexit`; `--record`: `norecord`,
    `noremux`, `zerots`; the cast probe's `recordlate`);
  - what happened on the real phone: `tools/dev/bridge_timeline.py --since HH:MM` (read-only) puts the phone's own log (lock screen,
    screen, USB functions, adbd restarts, scrcpy), the laptop's adb server log and the bridge trace on one clock: reproduce, then read;
  - the popup: `tools/dev/bridge_popup_probe.sh` (real clicks and wheels through the window; ARMs `tworeaders`, `escboth`,
    `noblock`, `lightjump`, `recordwindow`: Mirror with Record sent to scrcpy's window again);
  - the body: `tools/dev/bridge_body_probe.sh` (the body draws; cached = live; the display's edges whole pixels with the stage
    off the grid; every pose of a turn on its glass and inside the stage; still at rest; scales 1, 1.25, 1.5625; ARMs `hidden`,
    `nosnap`, `nogrid`, `nomatrix`, `nocache`, `leftclock`; `SHIM=1 LOCK_ENV=<name>` for the NVIDIA path, ARM `novert`),
    `tools/dev/bridge_flip_perf.sh` (what a frame costs), `tools/bridge/make_decor.py --check`;
  - the glyph: `tools/dev/glyph_flourish_probe.sh` (`bridge_*`; ARMs `bridgerest`, `bridgechain`, `bridgepop`, `bridgeunfold`, `bridgeseed`, `saluteopens`, `throughpier`, `hovercar`,
    `wrongway`, `smoothcast`, `castink`), `python3 tools/dev/flourish_parts.py --check`, `tools/dev/bar_hues_table.sh`.

## The desktop checklist (the real phone: no agent drives these)

1. Pair and unpair against the real KDE Connect.
2. Mirror in each mode by cable. Close the popup, restart the shell (`lares restart`) mid-mirror: it must still show and stop.
3. Plug in once (Keep wireless ready is on by default), unplug, Mirror over Wi-Fi; switch the phone's Wi-Fi off and on (a new
   address is likely) and mirror again. Pair Wireless debugging by its QR code; restart the phone; tap its quick tile; mirror.
3b. The cast: Mirror in the popup, tap, scroll, type, Left / Down / Right; resize the popup by its edges (it must not move; the
   "Resizing" hold, then a sharp picture); move it by the middle of its foot; the reset button; Sound; Window; Stop; close the popup
   and reopen within two minutes (the picture comes back), then after (it stopped). Desktop in the popup: its apps after a Stop.
   Start a cast with the phone locked and dark: it unlocks first and the picture comes. Lock it with its power key while the cast
   shows: the picture stays (no "Reconnecting"); click the picture: it wakes, holds "Unlocking", then shows the unlocked phone.
   A Desktop: the teal button and its app list are readable (no overlapping icons); resize the popup: the screen grows, nothing restarts.
   The phone dark and locked, start a Mirror, then Stop: it goes dark again at once. Leave a Mirror untouched for two minutes: the phone
   stays lit; close the popup and wait `closeAfterS` (2 min): it goes dark. Plug it in to charge afterwards: it still sleeps by itself.
3c. Unlock: Details > Unlock PIN > Set. Lock the phone, close and open the popup: it stays dark and locked (only a cast unlocks). Start
   a Mirror: it unlocks (by cable and over Wi-Fi). Once with a wrong PIN: one toast, and no second try at the next cast. Details shows
   "File transfer at unlock: Off".
   If anything stalls: `tools/dev/bridge_timeline.py --since <a minute before>`.
4. Files by cable with the phone locked, then unlocked; unplug while mounted, then Clean up.
5. Files over Wi-Fi after installing `sshfs`.
6. Send 1 GB by cable (the progress toast, the idle mode held at soft), one file over Wi-Fi.
7. Shot, Ring, Clipboard, the power key, the volume rocker.
8. Both faces in light and dark; the turn at every open. In a dGPU-only boot, look once that the body is drawn (the nested
   NVIDIA-path probe passes on Mesa; the real driver is only yours to check).
