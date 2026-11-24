# Windows follows themectl's light / dark

themectl writes the word `light` or `dark` to `~/Documents/windows/.theme/mode`, the shared folder from
`~/.config/windows/compose.yaml`. A small program in Windows reads it every 3 seconds and switches Windows.
The file sits on Linux, so a switch works with the VM off, and Windows picks the mode up at its next login.

This part was never run on Windows. It was written and read here, but this machine has no C# compiler, so step 2
is also the first time `ThemeSync.cs` gets compiled. If it fails, send the error back.

## 1. On Linux: put the files in the shared folder

Run a switch once, or the line below, so the folder exists and holds the current mode. Then copy the source there:

```bash
~/.config/quickshell/tools/theme/themectl apply --only windows-vm
cp ~/.config/quickshell/tools/theme/windows/ThemeSync.cs ~/Documents/windows/.theme/
```

`themectl` must print `ok    windows-vm   wrote ...` (or `unchanged`). `skipped` means it did not find the shared folder.

## 2. In Windows: compile it

Open **Command Prompt** (no Administrator needed) and run:

```bat
cd /d Z:\.theme
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /optimize+ /out:"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ThemeSync.exe" ThemeSync.cs
```

`csc.exe` comes with Windows and nothing gets installed. No output means it worked, and a line saying the compiler only supports
C# 5 is fine too. The program lands in your Startup folder, so it runs at every login, and it stays on the Windows disk, not in the shared folder.

## 3. Start it now

```bat
start "" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ThemeSync.exe"
```

There is no window: it runs in the background. It shows up as `ThemeSync.exe` in Task Manager.

## 4. Try it

On Linux, switch the theme with the popup or the bar button. Windows should follow within a few seconds:
the taskbar, Explorer and Settings at once, and programs that follow the system setting.

## What follows, and what does not

- **Follows:** the taskbar, Explorer, Settings, and programs set to use the system setting.
- **Does not:** older programs with their own fixed colours.
- **Picked by hand:** if you change the mode in Windows Settings, it stays until the next themectl switch.
- **Only light and dark:** not the accent colour. Windows has no public way to set it, and a half-applied accent could not be tested here.

## If it does nothing

1. In Windows, check the file: `type Z:\.theme\mode` must print `light` or `dark`.
2. If the drive is different from `Z:`, pass the path. Make a shortcut to `ThemeSync.exe` in the Startup folder instead of the program itself,
   and add the path after it, for example `ThemeSync.exe "\\host.lan\Data\.theme\mode"`.
3. Windows can cache a network folder for a few seconds, so give it up to 15 seconds before calling it stuck.

## Remove it

```bat
taskkill /im ThemeSync.exe
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ThemeSync.exe"
```

On Linux, `rm -r ~/Documents/windows/.theme` removes the folder. themectl makes it again on the next switch, as long as the VM's shared folder
is there. To stop that, set `"enabled": false` on `windows-vm` in `tools/theme/targets.json`.
