# Authentication prompts

## What it is

When something asks for a password -- an app through polkit (`pkexec`, a settings panel), the system update's `yay`, or a tool the
LLM runs with `sudo` -- the shell asks in one card: a toast with a password field and the face scan beside it. It replaces
polkit-gnome's window and sudo's terminal prompt with one place that looks like the lock screen and accepts the face too.

## Where it lives

- **The auth toast**: a sticky toast in the notifications' place at the top right ([notifications.md](notifications.md)). It is urgent, so it shows
  through do-not-disturb, and it has no swipe or dismiss: it is answered or cancelled.
- **Over a fullscreen window** the same card appears as a floating pill on top of the window (`modules/auth/AuthPillWindow.qml`),
  on the focused screen.
- **While the screen is shared** the card hides the user name and the action, but the request is still shown.
- No bar button, keyboard shortcut or IPC target of its own.

## What you can do

- **Type the password**: move the pointer onto the card (a card that appears under a resting pointer takes no keys), type, press
  Enter or click **Authenticate**. After the first key the card keeps the keyboard even when the pointer leaves it, until Enter,
  Escape or a click elsewhere.
- **Let the face do it**: when howdy is set up the scan runs as the card appears; the face glyph in the field shows it scanning,
  recognised or failed. A password typed during the scan is kept and answered as soon as the system asks for it.
- **Cancel**: the **Cancel** button. Escape clears what was typed and lets the keyboard go; the request stays.
- **Wrong password**: the field flushes to the error colour and the line under it says "Wrong password" with the number of attempts.
  There is never a lockout to wait for: only PAM's own short delay after a wrong password.
- **Several requests** wait in line: one card at a time, the oldest first.

## What it shows and where the data comes from

- **polkit**: the shell is the session's polkit agent (`modules/auth/data/PolkitSource.qml`, Quickshell's PolkitAgent). polkitd
  allows one agent per session: `lares` stops polkit-gnome, and if the shell's agent has still not registered 5 s after the
  start, the shell starts polkit-gnome itself, so authentication never silently stops. The card shows the action's message, the
  user and the action id.
- **sudo's askpass** (`modules/auth/data/AskpassSource.qml` + `modules/common/components/AskpassServer.qml`): a socket the shell
  serves while a run that may need sudo is going on. `llm_tools/askpass.py` is the program sudo runs as `SUDO_ASKPASS`: it sends the
  prompt to that socket and waits for the answer. The shell first checks that the asker descends from the run and that its parent is
  sudo running as root, so no command can open a password box by itself. The system update passes `helpers/sudo-askpass` to yay as its
  sudo, so every sudo call of a run (`--sudoloop`'s too) asks here, never on the run's terminal.
- **howdy**: `/etc/howdy/config.ini`, read by `modules/auth/data/HowdyConfig.qml` (`workaround` and `timeout`). With `workaround =
  native` the password prompt is open from the start, beside the scan; with `off` it opens after the scan.
- **The outcome** comes from the asker itself: polkit's flow, or for sudo whether the command went on (authenticated) or sudo exited
  (cancelled).

## Settings

There is no `auth.jsonc`. What the card does depends on the system:

- howdy's `/etc/howdy/config.ini` (`[core] workaround`, `[video] timeout`) -- the face's behaviour;
- `/etc/security/faillock.conf` `deny = 0` -- no lockout after wrong passwords (a system setting, set on this machine);
- polkit-gnome not started at login, so the shell's agent can register (`lares deploy` takes its autostart line out).

The card's look is tuned in `mockups/auth.qml` (the auth toast on the real bar engine); Save writes the module.

## How it is built

| File or directory | Role |
|---|---|
| `modules/auth/data/AuthBroker.qml` | every open request, one live at a time; `submit()` / `cancel()` |
| `modules/auth/data/PolkitSource.qml` | the polkit agent, as broker requests |
| `modules/auth/data/AskpassSource.qml` | sudo's askpass, as broker requests (built by the system update and the LLM tools) |
| `modules/auth/data/HowdyConfig.qml` | reads howdy's config |
| `modules/auth/AuthOwner.qml` | puts the current request in front of the user: the sticky toast, or the pill over fullscreen |
| `modules/auth/AuthCard.qml` | the card: title, user and action, the carved field with the face glyph, the status line, the two buttons |
| `modules/auth/AuthPill.qml`, `AuthPillWindow.qml` | the card on its own window over a fullscreen window |
| `modules/common/auth/AuthBus.qml` | where every part of the shell finds the one broker |
| `modules/common/components/AskpassServer.qml` | the askpass socket, the asker's check, the watch on sudo |
| `llm_tools/askpass.py`, `helpers/sudo-askpass` | sudo's side |

Shared: the lock screen's `LockField` and `LockStatusRow` (the field and the words under it, so failure reads the same as on the
lock), `HoverArm` (the keyboard only after a pointer motion), the notification service's toast and lane.

## Limits

- One polkit agent per session: while polkit-gnome runs, the shell's agent is refused and polkit-gnome's window asks instead.
- A face scan through polkit needs the drop-in that lets polkit's helper see the camera
  (`/etc/systemd/system/polkit-agent-helper@.service.d/howdy-camera.conf`, installed on this machine); without it polkit fails
  before any password is asked.
- A quick `sudo true` that ends and a third wrong try that ends look the same to the shell: both close the card as cancelled.

## How to change it

- **The card's look** (spacing, field, buttons): `quickshell -p ~/.config/quickshell/mockups/auth.qml`, tune, Save. Then
  `tools/dev/auth_render.sh smoke` and `tools/dev/auth_render.sh states <outdir>` to look at every state in light and dark.
- **The words** on the card: `modules/auth/AuthCard.qml`; the sources' titles: `PolkitSource.qml`, `AskpassSource.qml`.
- **After any change**: `tools/dev/smoke.sh mockups/auth.qml` and `tools/dev/shell_hosted_m2_probe.sh`.

Contract (for developers): [contracts/auth.md](contracts/auth.md).
