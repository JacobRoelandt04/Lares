# Auth — contract (stage 1, 2026-10-07)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/auth_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Fixed up front so the streams can be built in parallel. Facts: `0.md`. Plan and
decisions: `PLAN.md` (howdy `workaround = native` was chosen; until the user flips it
the machine is still `off`, and everything here must work under BOTH).

## Shared: `modules/common/components/PasswordBuffer.qml` (done, orchestrator)

A secret typed key by key, with no text field. Used by the lock's `AuthController`
and the auth card.
- `property int maxLength: 512`, `readonly property int length`.
- Signals:
  - `edited()`
  - `firstCharacter()`: a printable character went into an empty buffer.
  - `enterPressed(bool empty)`
  - `escapePressed()`
- Functions:
  - `handleKey(event) -> bool`: Return/Enter; Backspace; Escape, Ctrl+U and
    Ctrl+Backspace clear; printable characters append.
  - `take() -> string`: the secret, once; the buffer is empty afterwards.
  - `clear()`.
- Nothing else reads the text.

## Stream L — lockscreen stage 1b (agent; owns the lock's files)

Files:
- `modules/lockscreen/lock/AuthController.qml`
- `modules/lockscreen/lock/FaceAvailability.qml`
- `tools/dev/lock_env/pam_stub.c`
- `lock_auth_probe.sh` (+ its QML / fixtures)
- the lockscreen docs (`docs/lockscreen.md`,
  `docs/contracts/lockscreen.md`)

1. `AuthController` keeps its buffer in a `PasswordBuffer`. Behaviour unchanged:
   - `_buf` goes; dots = `buffer.length`.
   - The first character starts `_typingFace()`.
   - Enter on empty requests a face scan.
   - Every probe scenario still passes.
2. `FaceAvailability`:
   - Accepts `workaround = off` and `native`; `input` stays `misconfigured`.
     `input` is the only one that injects an Enter through uinput. The comment that
     groups native with it is wrong and is corrected.
   - It exposes `howdyWorkaround` ("off" | "native" | ...) and `howdyTimeoutMs`
     (`[video] timeout`, s → ms; default 4000) for the controller.
3. `AuthController` under `native`:
   - The face stack PROMPTS at once (howdy asks for the password on a second
     thread). That is expected, not `misconfigured`: hold the prompt UNANSWERED.
     Answering kills the scan.
   - A failed face sends NO message (howdy then waits for a password for ever), so
     the controller ends the scan itself: abort the face context (`_abortFace`, the
     reap included) at `howdyTimeoutMs + margin` (margin ~1500 ms for the camera's
     start).
   - The state reads as a failed scan, reason `"timeout"`; the dark/camera/lid
     reasons are unknowable under native.
   - A face win under native still ends in `PamResult.Success` (measured: howdy
     cancels its own prompt thread).
   - Under `off` everything stays as it is. The misconfigured check for a prompting
     face stack stays for `off` (there it IS a misconfiguration).
4. `pam_stub` gains what the probe needs to imitate native: a prompt that is never
   answered while a later `return` decides (e.g. `prompt-async TEXT` sends the prompt
   from a thread and does not wait for it), or whatever shape the agent finds
   simplest that mimics the measured order:
   - prompt at ~0 ms;
   - success at face time;
   - no message on a failed face, then an endless wait.
5. New probe scenarios:
   - `nativewin`: the face stack prompts at once and then succeeds → unlock, the
     prompt never answered.
   - `nativefail`: prompts, never ends → aborted at timeout + margin, reads as a
     failed scan, the password still unlocks.
   - `inputmode`: `workaround = input` → misconfigured.
   - An ARM that answers the face stack's prompt must go red.
6. Gate: `lock_auth_probe.sh` all scenarios + `--arms`, lint, smoke.

## Stream A — askpass extraction (agent; owns these files)

Files:
- new `modules/common/components/AskpassServer.qml`
- `modules/bar/llm/components/LlmTools.qml` (the askpass section only)
- `llm_tools/askpass.py` (keep its protocol)
- `llm_askpass_probe.sh` + `test_llm_askpass_probe.qml` + `stub_sudo.sh`

`AskpassServer.qml` is the generic half of LlmTools' round-20 server: the socket, the
request verification (the claimed pid descends from a ROOT pid, and its parent is a
process named `sudo` with euid 0), the faillock reading, the expiry, and the
answer/close discipline (whoever closes first).

```
AskpassServer {
    property string path                 // socket path; served only while `active`
    property bool   active
    property int    rootPid              // requests must descend from it
    property bool   requireSudoParent: true
    property int    answerWindowMs: 120000   // withdrawn 2 s before the helper gives up
    readonly property var request        // null | { id, pid, prompt, failures, deny, unlockS }
    signal requested(var request)        // verified, shown-worthy
    signal withdrawn(string id)          // helper gone / expired / refused after publish
    function answer(id, secret)          // "" = cancel
    function cancel(id)
}
```

One request at a time per server: a second connection while one is open is answered
"" at once (as now). `LlmTools` keeps its public `authRequest` / `answerAuth` /
`cancelAuth` exactly; internally it uses one `AskpassServer` with
`rootPid = _proc.processId` and decorates the record with its job's fields (name,
glyph, howdy, detail, ...). The LLM popup and its card do not change in this stage.

Gate: `llm_askpass_probe.sh` — every scenario and every ARM as before. Plus a
small offscreen probe of AskpassServer alone if the LLM probe does not cover refusal
by ancestry.

## Stream B — broker + polkit source (orchestrator)

Files:
- `modules/auth/data/{AuthBroker,PolkitSource,HowdyConfig}.qml`
- `modules/common/auth/AuthBus.qml` (+ qmldir)
- `test_auth_broker_probe.qml`, `auth_broker_probe.sh`

`AuthBroker`: the requests the shell is asked to authenticate, one live at a time
(polkit itself queues; Quickshell's agent activates the next flow when one ends).

A record (a new object on every change):
```
{ id, source: "polkit"|"askpass", title, body, detail, iconName, user,
  identities: [names], identityIndex,
  prompt: "" (no prompt open) | text, echo: bool,
  face: "none"|"scanning"|"ok"|"failed", faceUntil: epoch ms,
  state: "idle"|"checking"|"failed"|"ok"|"cancelled",
  message, isError, failCount, held: bool (an Enter waiting for the prompt) }
```

API:
- `open(spec, handlers) -> id`, with `handlers = { respond(secret), cancel(),
  selectIdentity(i) }`.
- `update(id, patch)`.
- `finish(id, outcome)`.
- `submit(id, secret)`: answered at once when a prompt is open, otherwise held and
  answered when one opens.
- `cancel(id)`.
- `selectIdentity(id, i)`.
- Read-only `current`, `requests`, `count`.
- Signals `opened(record)`, `changed(record)`, `closed(id, outcome)`.

`AuthBus` (singleton) holds `broker`; only the broker writes it.

`HowdyConfig`: `mode` ("off"|"native"|"input"|"disabled"|"absent"), `timeoutMs`,
read from `/etc/howdy/config.ini` (`path` overridable for tests).

`PolkitSource`:
- `broker`, `enabled`, and `agent` (the real `PolkitAgent` by default; a probe
  injects a fake with the same properties).
- Face line:
  - `scanning` from the flow's start while howdy is usable.
  - `ok` on `Identified face`.
  - `failed` on howdy's failure lines (off mode).
  - Native has no failure line, so `faceUntil` = start + `timeoutMs` + 1500, after
    which the line drops to `none`.
- Each failed session (the flow restarts itself) is `state: failed`, `failCount++`,
  and the face is scanning again.

---

# Stage 2 contract (2026-10-07)

Decided:
- The toast is a NotificationService post: urgency `critical`, so it is sticky, shows
  through fullscreen/screencast holds and DnD, and is held while locked. These are
  NotifyPolicy's existing rules; `auth` is already in `dnd.breakthroughSources`.
- **Over fullscreen** the lane is invisible: the engine window is Top, and
  NotificationHolds holds toasts there. So AuthOwner presents in its OWN Overlay
  window (`AuthPillWindow`), like the OSD's pill. This needs no engine edit.
- **The only engine edit** is the catch rect.

Shared pieces already in: `PasswordBuffer`, `HoverArm` (incl. `releaseOnOutsidePress`
/ `outsidePressed`), `AuthBroker` / `PolkitSource` / `HowdyConfig` / `AuthBus`.

## Stream N — notifications + engine (agent)

Files:
- `modules/notifications/data/NotificationService.qml`
- `modules/notifications/NotificationToast.qml`
- `modules/notifications/toast/{ToastEntry,ToastSlot}.qml`
- `modules/notifications/parts/NotificationCard.qml` (only if `fixed` needs it)
- `modules/bar/gooey/GooeyEngine.qml` (the catch rect ONLY)
- their probes/tests, and the notifications + engine docs

API:
1. **`post({ fixed: true })` → `rec.fixed`.**
   - The toast has no swipe verbs (`rightVerb`/`leftVerb` ""), a body click does
     nothing, and nothing the user does on the card's chrome removes it.
   - The poster ends it with `withdraw(source, key)` / `withdrawUid(uid)`.
   - A fixed record is never filed to the manager on its own: it is live UI, not
     history. It is dropped, not filed, when withdrawn.
2. **`setInteraction(token, { keyboard: "none"|"onDemand"|"exclusive", catchAll: bool })`**,
   `clearInteraction(token)`, and `readonly property var interaction`
   (`{ keyboard, catchAll }`, the strongest over all tokens; a new object on change).
3. **`NotificationToast`:**
   - `keyboardFocusRequest` = the strongest of (`_replying ? "onDemand" : "none"`)
     and `service.interaction.keyboard`.
   - New `readonly property bool maskCatchAll: service.interaction.catchAll`.
4. **`GooeyEngine`:** while the lane is live and its content has
   `maskCatchAll === true` (read like `_keyboardOf`: `"maskCatchAll" in it`), one more
   rect `{0, 0, track.w, track.h}` goes into `maskRects` before the write loop.
   Nothing else in the engine changes (the user's scoped permission).
5. A rich body is loaded once with `bodyProps` (unchanged). The auth body gets
   `{ broker, requestId, service, token }` there.

Gate:
- A probe: the catch rect appears in `maskItems` on request and is gone after.
- `engine.keyboardFocus` follows the toast's request.
- A fixed toast does not commit a swipe nor activate on a click.
- Every existing notifications/lane probe still passes:
  - `notifications_ui_probe`
  - `notifications_toast_r2_probe`
  - `notifications_manager_r2_probe`
  - `gooey_lane_probe`
  - `gooey_lane_cycle_probe`
  - `gooey_lane_closecut`
  - `tools/dev/notifications_mockup.sh` smoke
  - and any other it touches

## Stream C — the auth UI (agent)

Files:
- `modules/auth/AuthCard.qml`, `modules/auth/AuthOwner.qml`,
  `modules/auth/AuthPillWindow.qml`
- `test_auth.qml` (mockup)
- `tools/dev/auth_render.sh`, `auth_card_probe.sh` (+ QML)

**AuthCard** (the rich body; also hosted by the pill):
- Inputs: `broker`, `requestId`; `service` and `token` (in a toast; null in the
  pill).
- `showHeader` (the pill draws title + body itself; in a toast the card's own
  summary/body do).
- Outputs: `readonly property string keyboardRequest` (`arm.armed ? "exclusive" :
  "none"`) and `readonly property bool catchAll` (`arm.sticky && !arm.hovered`).
- In a toast it pushes both to `service.setInteraction(token, ...)` and clears them
  on destruction.
- Inside:
  - `HoverArm { target: <the card>; active: visible && record live }`.
  - A `PasswordBuffer`.
  - A focus sink with `Keys.onPressed → buffer.handleKey`, given `forceActiveFocus()`
    when armed.
  - A local `LockState` mirrored from the record.
- Mapping:
  - `dots` = `buffer.length`.
  - `auth` = record `state` (`held` → "checking"; "cancelled" → "idle").
  - `face`: none → "absent", others 1:1.
  - `failCount`, `authMessage` = record `message`.
- It draws `LockField` (smaller sizes for a toast) and `LockStatusRow` from
  `modules/lockscreen/popup` (the lockscreen language the user picked), then two
  `RaisedButton`s, Cancel and Authenticate (`accent`).
- Keys:
  - The first key → `arm.latch()`.
  - Enter → `broker.submit(id, buffer.take())`, `arm.release(false)`.
  - Escape → the buffer clears (PasswordBuffer does it), `arm.release(true)`.
  - Cancel button → `broker.cancel(id)`.
- Paddings, radii, fonts and colours follow CLAUDE.md's design language; themed
  tokens only.

**AuthOwner:**
- Inputs: `broker`, `service`, `fullscreen` (FullscreenWatch), `sharing` (the
  service's screencast hold).
- For `broker.current`, it posts `{ source: "auth", key: rec.id, title, body:
  sharing ? "" : rec.body, urgency: "critical", timeoutMs: -1, fixed: true,
  bodyComponent, bodyProps }`.
- It updates on record change and withdraws on close.
- While `fullscreen`, no toast: the same card in `AuthPillWindow`. On a fullscreen
  flip it moves between the two, keeping the typed buffer: the buffer lives in the
  owner per request, and the card takes it as an input. The OSD's `_surfaceFlip` is
  the model.

**AuthPillWindow:**
- `PanelWindow`, Overlay, top-anchored, spanning the output, transparent.
- `mask`: the card's rect, or the whole output while `card.catchAll`.
- `WlrLayershell.keyboardFocus` from `card.keyboardRequest`.

**test_auth.qml** (mockup on the real engine, like `test_notifications.qml`):
- In-process NotificationService + AuthBroker + PolkitSource with a fake agent.
- A Run tab with scripted timelines:
  - native face win
  - native password
  - off held Enter
  - wrong then right
  - cancel
  - two queued
  - fullscreen flip
- Card params on their own tab (field height, dot size, radii, button gap), each
  with a tip and group.
- Renders: face scanning / password typed / checking / failed / ok, light and
  dark.

---

# Stage 3 contract (2026-10-07): sudo's askpass through the broker

Facts (measured by the user, `auth_sudo_native_measure.sh`, howdy native, face
won):
- sudo started the askpass helper **30 ms** in, beside the scan.
- sudo exited at 1943 ms **without waiting for the helper**. The helper only noticed
  because it polled for its parent.
- howdy's "Identified face" went to the TERMINAL, not stderr.

So under native, every sudo opens an askpass request at once, and a face win must
be detected from the PROCESSES. With a long command, sudo stays alive (running it)
while our real helper would sit on its socket for 120 s.
`/proc/<pid>/task/<pid>/children` is world-readable, a root sudo's included.

## Stream S3a: AskpassServer settle watch + AskpassSource + the LLM (agent)

Files:
- `modules/common/components/AskpassServer.qml`
- new `modules/auth/data/AskpassSource.qml`
- `modules/common/components/{LlmTools,LlmService,LlmConfirmPanel,LlmComposer,LlmPopup}.qml`
  (the askpass/password parts only)
- their probes: `askpass_server_probe.sh`, `llm_askpass_probe.sh` + QML
- a new `askpass_source_probe.sh` + QML

1. **AskpassServer:**
   - The request gains `sudoPid` (the verified parent).
   - The server WATCHES each sudo that asked, from its first request until it settles
     or `watchMs` (default 600000) passes, by reading
     `/proc/<sudoPid>/task/<sudoPid>/children` (FileView `reload()`, no fork; ~200 ms
     while watching, nothing otherwise).
   - Settled = sudo has a child that is not its askpass helper ("moved-on": the
     command runs, so it authenticated), or sudo is gone ("gone").
   - On settle it emits `sudoSettled(int sudoPid, string how)`. If that sudo's
     request still stands, the server answers it "" and closes the connection itself
     (the orphaned helper exits 1; sudo no longer waits on it) and emits
     `withdrawn(id)` first.
2. **AskpassSource** binds one server to the broker:
   - Properties: `broker`, `server`, `title`, `describe` (a function(request) →
     `{ body, detail }` supplied by the client), `howdyMode`, `faceTimeoutMs`,
     `faceMarginMs`.
   - On `requested(r)`:
     - A record already open for `r.sudoPid` (the retry after a wrong password)
       becomes `{ state: "failed", failCount + 1, prompt: r.prompt }`.
     - Otherwise it opens `{ source: "askpass", prompt: r.prompt (open at once),
       face: scanning (native: until faceUntil, like PolkitSource) }`.
   - Handlers: `respond` → `server.answer`; `cancel` → `server.cancel` +
     `finish("cancelled")`.
   - `sudoSettled(pid, "moved-on")` → `finish(record, "ok")`.
   - `sudoSettled(pid, "gone")` → `finish(record, "cancelled")`. An honest close:
     a quick `sudo true` and a third wrong try both end with sudo gone and cannot be
     told apart.
   - `withdrawn` with no settle (expiry, helper died) → `finish("cancelled")`.
3. **The LLM:**
   - `LlmTools` keeps its public API for its probes. The UI no longer draws a
     password field: `LlmConfirmPanel`'s password mode and its focus-stealing are
     deleted.
   - Requests go to the broker through an `AskpassSource` (`describe`: the tool
     job's name and command).
   - The composer shows one quiet line while a request stands ("asked in the
     authentication toast").
   - With no broker on `AuthBus` (an LLM mockup alone), the request is cancelled at
     once, with an activity line that says why.

## Stream S3b: the system update's sudo through askpass (agent)

Files:
- `helpers/update-run.sh`
- `llm_tools/askpass.py`, or a generic copy at `tools/auth/askpass.py` (then the LLM
  points at it too; coordinate by NOT editing LlmTools: S3a owns it, so keep both
  env names working)
- `modules/common/components/{SystemUpdatePopup,SystemUpdateHelperDriver,TerminalBackend}.qml`
  (the password parts only)
- the system-update probes (`test_authcard_probe.qml` and whatever covers the
  password card)

- yay runs with `--sudo helpers/sudo-askpass` (`exec sudo -A "$@"`). `--sudoflags -A`
  was the first version and missed --sudoloop's `sudo -v`, which yay runs with no
  flags (the real run of 2026-10-08 waited on the PTY for it). Plus
  `SUDO_ASKPASS` = the helper and a STABLE socket path
  (`$XDG_RUNTIME_DIR/lares-askpass-update.sock`) set in `update-run.sh`.
- The run is detached and outlives a shell reload, so the helper RETRIES connecting
  (a new shell re-serves the same path) until its own timeout.
- The popup serves an `AskpassServer` (`rootPid`: the run's pid from `run.json`)
  with an `AskpassSource` (`describe`: "System update", the command yay is running).
- The PTY password path stops being the way a password is given:
  - the status card points at the toast;
  - no secret is ever written to `stdin.fifo` (the face can win the same instant;
    bytes into a PTY nobody reads as a password land in the next reader,
    echoed).
- pkexec already goes through polkit, so nothing changes there.
