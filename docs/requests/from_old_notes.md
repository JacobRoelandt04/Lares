# Open requests from the old module notes

The cleanup deleted the old per-module notes (git keeps them: tag `pre-cleanup`). These are the requests in YOUR words, quoted from those notes,
that the code does not fully do. Each line says what it does today, as read from the code. Nothing here is planned: move a line to `feedback/` to
ask for it, or delete it.

| # | Your words | From | What the code does today |
|---|---|---|---|
| 1 | "a toggleable button somewhere in the GUI ... When toggled, the session will not be killed by closing the popup, letting me come back to where I left off" | `large_language_model.md` | Partly: the pin keeps the model and the answer running, but the popup is rebuilt on every open, so scroll position and folds are lost. |
| 2 | "all sorts of functionalities (file sharing, image generation)" | `large_language_model.md` | Image generation is not built. |
| 3 | "Moon (rise/set times + shape)" | `weather.md` | The moon tile shows the phase only; rise and set are in the detail view. |
| 4 | "Maybe later down the line a gui is made." (for the portfolio) | `stock.md` | The portfolio is edited in `stocks.jsonc` only. |
| 5 | "having the notion/obsidian-like live markdown interpretation would be cool to have" | `notes.md` | Built, except: callouts never fold, and tables cannot be edited cell by cell. |
| 6 | "some tools to see what packages might want to be uninstalled. prompt LLM for further information" | `system_update.md` | Not built. |
| 7 | "old logs are automatically deleted after they are 2 updates old" | `system_update.md` | Not done: every run's transcript is kept, on purpose, for reading back a run that went wrong. Say if you want the limit anyway. |
| 8 | "system update information must have a toggleable "flag" for every package provider source" | `README.md` | There is no switch per source (repo, AUR, flatpak). |
| 9 | "Configurable maximum framerate for the calendar animations." | `clock.md` | Not built. |
| 10 | "low device battery" (in the Bluetooth list of notification sources) | `notifications.md` | Nothing warns about a Bluetooth device's battery. |
| 11 | "Needs further testin once deployed" | `wiki.md` | A hands-on test for you after the turnover, not a code change. |
| 12 | "Potentially the charging and discharging animations ... run continuisly on an interval that is governed by the Watts" | `battery.md` (merged into silicon) | Probably superseded by silicon's board; listed in case it is not. |
