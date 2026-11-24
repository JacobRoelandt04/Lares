// ThemeSync.cs -- the Windows half of themectl's windows-vm target: makes Windows follow the mode the Linux side wrote to the shared folder.
//
// themectl writes the word `light` or `dark` to .theme/mode in the shared folder. This reads it every few seconds and, when the word changes, sets the two values Settings sets
// (apps and system) and tells the running programs. It starts with the session, so a Windows that was off when the theme changed comes up in the right mode.
//
// It trusts the file for ONE thing. The VM and the host can both write that folder, so the file is data and nothing else: at most 32 bytes, exactly the word light or dark, and
// anything else is ignored. Nothing from it is ever run, opened, or used as a path or a registry name.
//
// A change is applied once, so a mode picked by hand in Windows stays until themectl next says otherwise.
//
// C# 5 on purpose: this is what the csc.exe inside Windows compiles (no ?. or $"" or =>). tools/theme/windows/INSTALL.md has the steps.
//
//     ThemeSync.exe [path to the mode file]         default Z:\.theme\mode
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

static class ThemeSync
{
    const string DefaultPath = @"Z:\.theme\mode";
    const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    const int MaxBytes = 32;
    const int PollMs = 3000;

    const uint WM_SETTINGCHANGE = 0x001A;
    const uint SMTO_ABORTIFHUNG = 0x0002;
    const uint BroadcastTimeoutMs = 500;
    static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeoutMs, out UIntPtr result);

    static int Main(string[] args)
    {
        string path = args.Length > 0 ? args[0] : DefaultPath;
        bool first;
        // One per session: Local\, and a second start simply leaves.
        using (Mutex one = new Mutex(true, @"Local\ThemeSync", out first))
        {
            if (!first)
                return 0;
            string applied = null;
            while (true)
            {
                try
                {
                    string want = ReadMode(path);
                    if (want != null && want != applied)
                    {
                        Apply(want);
                        applied = want;
                    }
                }
                catch (Exception)
                {
                    // The drive is not mapped yet, the VM is short of memory, the registry said no: the next round tries again. This program has no window to complain in.
                }
                Thread.Sleep(PollMs);
            }
        }
    }

    // The word in the file, or null for anything else: a missing file, a longer one, other words, other bytes.
    static string ReadMode(string path)
    {
        byte[] bytes = new byte[MaxBytes + 1];
        int n;
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            n = f.Read(bytes, 0, bytes.Length);
        }
        if (n > MaxBytes)
            return null;
        string word = Encoding.ASCII.GetString(bytes, 0, n).TrimEnd('\r', '\n');
        return word == "light" || word == "dark" ? word : null;
    }

    static void Apply(string mode)
    {
        int light = mode == "light" ? 1 : 0;
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(PersonalizeKey))
        {
            key.SetValue("AppsUseLightTheme", light, RegistryValueKind.DWord);
            key.SetValue("SystemUsesLightTheme", light, RegistryValueKind.DWord);
        }
        // What Settings broadcasts: the taskbar, Explorer and the programs that follow the system re-read the two values on this. Hung windows are skipped, not waited for.
        UIntPtr result;
        SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero, "ImmersiveColorSet", SMTO_ABORTIFHUNG, BroadcastTimeoutMs, out result);
    }
}
