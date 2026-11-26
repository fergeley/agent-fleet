using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class FleetWindow
{
    private delegate bool WindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr window, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetProp(IntPtr window, string name, IntPtr value);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint code);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo
    {
        public int Size;
        public Rectangle Monitor, Work;
        public uint Flags;
    }

    private static bool IsTerminalWindow(IntPtr window)
    {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        try {
            using (var process = Process.GetProcessById((int)processId)) {
                return process.ProcessName == "WindowsTerminal";
            }
        } catch { return false; }
    }

    // The windows of Windows Terminal that pass the test. The cheap test comes first, so that the process of a window is read only for a match.
    private static long[] Enumerate(bool requireVisible, Func<IntPtr, string, bool> accept)
    {
        var matches = new List<long>();
        EnumWindows((window, data) => {
            if (requireVisible && !IsWindowVisible(window)) return true;
            var title = new StringBuilder(1024);
            GetWindowText(window, title, title.Capacity);
            if (!accept(window, title.ToString())) return true;
            if (!IsTerminalWindow(window)) return true;
            matches.Add(window.ToInt64());
            return true;
        }, IntPtr.Zero);
        return matches.ToArray();
    }

    // The windows that Fleet registered. A registered window counts also when Terminal has hidden it.
    public static long[] Find(string property)
    {
        return Enumerate(false, (window, caption) => GetProp(window, property) != IntPtr.Zero);
    }

    // The visible windows that a Fleet launch can have opened, by title. Fleet.ps1 uses it only while a launch is pending.
    public static long[] FindByTitle()
    {
        return Enumerate(true, (window, caption) => caption.StartsWith("Agent Fleet [", StringComparison.Ordinal));
    }

    public static long[] FindTitle(string title)
    {
        return Enumerate(false, (window, caption) => String.Equals(caption, title, StringComparison.Ordinal));
    }

    public static long[] FindTitlePrefix(string prefix)
    {
        return Enumerate(false, (window, caption) => caption.StartsWith(prefix, StringComparison.Ordinal));
    }

    // The windows with the startup title of a job or shared Jobs window of this installation. A test copy has another tag.
    public static long[] FindJobTitles(string installationTag)
    {
        return Enumerate(false, (window, caption) =>
            (caption.StartsWith("Agent Fleet Job [", StringComparison.Ordinal) && caption.Contains(" | " + installationTag + "/")) ||
            caption.StartsWith("Agent Fleet Jobs | " + installationTag + "/", StringComparison.Ordinal));
    }

    public static bool HasProperty(long handle, string property)
    {
        var window = new IntPtr(handle);
        return !String.IsNullOrEmpty(property) && GetProp(window, property) != IntPtr.Zero && IsTerminalWindow(window);
    }

    public static FleetWindowObservation[] Observe(string exactTitle, string instanceProperty)
    {
        return Observe(exactTitle, instanceProperty, null);
    }

    public static FleetWindowObservation[] Observe(string exactTitle, string instanceProperty, string windowProperty)
    {
        var found = new List<FleetWindowObservation>();
        Exception failure = null;
        bool complete = EnumWindows((window, data) => {
            try {
                var caption = new StringBuilder(1024);
                SetLastError(0);
                if (GetWindowText(window, caption, caption.Capacity) == 0 && Marshal.GetLastWin32Error() != 0)
                    throw new InvalidOperationException("Window caption query failed.");
                bool titleMatch = String.Equals(caption.ToString(), exactTitle, StringComparison.Ordinal);
                bool propertyMatch = !String.IsNullOrEmpty(instanceProperty) && GetProp(window, instanceProperty) != IntPtr.Zero;
                bool windowPropertyMatch = !String.IsNullOrEmpty(windowProperty) && GetProp(window, windowProperty) != IntPtr.Zero;
                if (!IsWindow(window))
                    throw new InvalidOperationException("Window property query failed.");
                if (!titleMatch && !propertyMatch && !windowPropertyMatch) return true;
                uint pid;
                if (GetWindowThreadProcessId(window, out pid) == 0 || pid == 0)
                    throw new InvalidOperationException("Window process query failed.");
                string started;
                using (var process = Process.GetProcessById((int)pid)) {
                    if (!String.Equals(process.ProcessName, "WindowsTerminal", StringComparison.Ordinal)) return true;
                    started = process.StartTime.ToUniversalTime().ToString("o");
                }
                int cloaked;
                int cloakResult = DwmGetWindowAttribute(window, 14, out cloaked, sizeof(int));
                found.Add(new FleetWindowObservation {
                    Handle = window.ToInt64(), Pid = (int)pid, ProcessStartUtc = started,
                    TitleMatch = titleMatch, PropertyMatch = propertyMatch, WindowPropertyMatch = windowPropertyMatch,
                    Visible = IsWindowVisible(window), Minimized = IsIconic(window),
                    Cloaked = cloakResult == 0 ? (bool?)(cloaked != 0) : null,
                    CloakQuery = cloakResult == 0 ? "ok" : "error"
                });
                return true;
            } catch (Exception error) {
                // A window that closed during the enumeration is absent, not a failed query.
                if (!IsWindow(window)) return true;
                failure = error;
                return false;
            }
        }, IntPtr.Zero);
        if (failure != null) throw new InvalidOperationException("Window observation failed.", failure);
        if (!complete) throw new InvalidOperationException("Window enumeration failed.");
        return found.ToArray();
    }

    public static int[] GetCurrentWorkArea()
    {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            Point point;
            if (!GetCursorPos(out point)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            if (!GetMonitorInfo(MonitorFromPoint(point, 2), ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return new[] { info.Work.Left, info.Work.Top, info.Work.Right - info.Work.Left, info.Work.Bottom - info.Work.Top };
        } finally { SetThreadDpiAwarenessContext(previous); }
    }

    public static int[] TileBounds(int[] area, int count, int index)
    {
        if (area == null || area.Length != 4 || area[2] < 1 || area[3] < 1) throw new ArgumentException("The work area must contain a positive width and height.");
        if (count < 1 || count > 4) throw new ArgumentOutOfRangeException("count");
        if (index < 0 || index >= count) throw new ArgumentOutOfRangeException("index");
        int columns = count == 1 ? 1 : 2;
        int rows = count > 2 ? 2 : 1;
        if (area[2] < columns || area[3] < rows) throw new ArgumentException("The work area is too small for this layout.");
        int column = index % columns;
        int row = index / columns;
        int left = area[0] + area[2] * column / columns;
        int top = area[1] + area[3] * row / rows;
        int right = area[0] + area[2] * (column + 1) / columns;
        int bottom = area[1] + area[3] * (row + 1) / rows;
        return new[] { left, top, right - left, bottom - top };
    }

    public static bool Place(long handle, string property, int x, int y, int width, int height)
    {
        if (width < 1 || height < 1 || !HasProperty(handle, property)) return false;
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) return false;
        try {
            var window = new IntPtr(handle);
            ShowWindowAsync(window, 4);
            return SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x4054);
        } finally { SetThreadDpiAwarenessContext(previous); }
    }

    // False when the thread of the window does not answer a WM_NULL within two seconds, as a hung window does not.
    public static bool IsResponsive(long handle)
    {
        IntPtr result;
        // SMTO_ABORTIFHUNG returns at once for a window that Windows already counts as hung.
        return SendMessageTimeout(new IntPtr(handle), 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0002, 2000, out result) != IntPtr.Zero;
    }

    // Place the window on the work area, then maximize it there, so that it stays maximized on the monitor under the pointer.
    public static bool Fill(long handle, string property, int[] area)
    {
        if (area == null || area.Length != 4) return false;
        if (!Place(handle, property, area[0], area[1], area[2], area[3])) return false;
        return ShowWindowAsync(new IntPtr(handle), 3);
    }

    // The environment that Windows gives this user at sign-in, without the variables of the calling shell.
    public static Dictionary<string, string> GetSignInEnvironment()
    {
        IntPtr token;
        // TOKEN_QUERY | TOKEN_DUPLICATE, which CreateEnvironmentBlock needs for a primary token.
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0002, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr block;
            if (!CreateEnvironmentBlock(out block, token, false)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                int offset = 0;
                while (true) {
                    string entry = Marshal.PtrToStringUni(IntPtr.Add(block, offset));
                    if (String.IsNullOrEmpty(entry)) break;
                    offset += (entry.Length + 1) * 2;
                    int separator = entry.IndexOf('=');
                    // An entry such as "=C:=C:\" holds a drive's current directory, not a variable.
                    if (separator <= 0) continue;
                    variables[entry.Substring(0, separator)] = entry.Substring(separator + 1);
                }
                if (variables.Count == 0) throw new InvalidOperationException("The sign-in environment is empty.");
                return variables;
            } finally { DestroyEnvironmentBlock(block); }
        } finally { CloseHandle(token); }
    }

    public static bool Register(long handle, string property)
    {
        return SetProp(new IntPtr(handle), property, new IntPtr(1));
    }

    public static bool Focus(long handle)
    {
        var window = new IntPtr(handle);
        // SW_RESTORE shows a window that Terminal hid, and restores a minimized one.
        if (!IsWindowVisible(window) || IsIconic(window)) ShowWindowAsync(window, 9);
        return SetForegroundWindow(window);
    }
}

public sealed class FleetWindowObservation
{
    public long Handle { get; set; }
    public int Pid { get; set; }
    public string ProcessStartUtc { get; set; }
    public bool TitleMatch { get; set; }
    public bool PropertyMatch { get; set; }
    public bool WindowPropertyMatch { get; set; }
    public bool Visible { get; set; }
    public bool Minimized { get; set; }
    public bool? Cloaked { get; set; }
    public string CloakQuery { get; set; }
}
