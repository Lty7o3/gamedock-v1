# ============================================================
#   GAMEDOCK V2  -  one-paste installer
# ============================================================
#   V3.4 - THE HONEST HOURS UPDATE
#    - Idle guard: AFK 10+ minutes? counting pauses - no
#      more fake overnight hours inflating your stats
#    - Session goal (tray menu): pick 1-4h, get a gentle
#      tray warning when a session passes it
#    - Ctrl+Shift+F toggles the FPS overlay from ANYWHERE,
#      even while you're in-game
#    - Stats page: This Week / This Month now show trend
#      arrows vs the previous week/month
#   V3.3 - THE COMMAND UPDATE
#    - Right-click any game bubble: launch, rename, set
#      tracked process, open file location, reset playtime,
#      remove (the tiny pencil/X buttons are retired)
#    - SCAN button: finds installed games automatically
#      (Steam libraries, Epic Games, Start Menu) - tick the
#      ones you want, they're all added at once
#    - Tray menu: Backup data to Desktop / Restore backup
#   V3.2 - THE SHOWPIECE UPDATE
#    - Monthly WRAPPED: on the 1st launch of a new month, a
#      recap card pops up - total time, trend vs last month,
#      top game, days played, best streak, biggest session
#      (also anytime: gift button in the Stats page)
#    - SHARE button in Stats: saves a big stats card PNG to
#      your Desktop - perfect for Discord flexing
#    - Games currently running get a pulsing gold glow
#   V3.1 - THE ALWAYS-ON UPDATE
#    - Start with Windows (tray icon right-click > tick it):
#      GameDock boots hidden in the tray, so playtime,
#      sessions and streaks never miss a day
#    - Bubbles now show last played + times launched
#    - New sort button: RECENT / MOST PLAYED / A-Z
#    - Tray "still running" tip now shows ONCE ever
#   V3.0 ALPHA - THE STATISTICS UPDATE
#    - Automatic session tracker: every play session logged
#      (start, duration; + avg FPS / 1% low / avg CPU when
#      the FPS overlay is ON while you play)
#    - New STATS page: totals, this week/month, longest
#      session, day-by-day chart, most played, streaks
#    - Redesigned FPS overlay: smoother number, 1% low,
#      color-coded (green/amber/red), sleeker card look
#    - Tray pop-up now only shows the first time you hit X
#    - All of v2.3: tray mode, single instance, smart
#      playtime for Roblox/Forza, pencil override
#    - v2.1: smart playtime for Roblox / Forza / Store games
#      + pencil button to set the tracked process per game
#    - Everything from v2: playtime, FPS overlay, search,
#      navy + gold UI, gold-ring icon
#   HOW TO USE: paste this WHOLE script into PowerShell, Enter.
#   Upgrading? Games and playtime carry over automatically.
# ============================================================

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'GameDock'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$desktop = [Environment]::GetFolderPath('Desktop')

# ---------- 0. Close running copy ----------
Get-Process GameDock -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

# ---------- 1. App source (C# / WPF) ----------
$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace GameDock
{
    public class GameEntry
    {
        public string Name;
        public string Path;
        public long Seconds;
        public string ExeName;   // resolved process name for playtime tracking
        public string TrackName; // manual override of the tracked process
        public int Launches;     // how many times started from GameDock or detected running
        public long LastPlayed;  // last time seen running (ticks), 0 = never
    }

    public class SessionEntry
    {
        public string Game;
        public DateTime Start;
        public long Seconds;
        public int AvgFps;   // -1 = overlay was off, no data
        public int LowFps;   // -1 = no data
        public int AvgCpu;   // -1 = no data
    }

    public static class Program
    {
        [DllImport("user32.dll")]
        static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        static extern uint RegisterWindowMessage(string lpString);

        public static uint WM_SHOWGAMEDOCK;

        [STAThread]
        public static void Main()
        {
            WM_SHOWGAMEDOCK = RegisterWindowMessage("GAMEDOCK_SHOW_V1");
            bool createdNew;
            System.Threading.Mutex mutex = new System.Threading.Mutex(
                true, "GameDock_SingleInstance_Mutex", out createdNew);
            if (!createdNew)
            {
                // another GameDock is already running (maybe hidden in the tray):
                // ask it to show itself, then quit immediately - no double tracking.
                PostMessage(new IntPtr(0xffff) /* HWND_BROADCAST */,
                    WM_SHOWGAMEDOCK, IntPtr.Zero, IntPtr.Zero);
                return;
            }
            try
            {
                Application app = new Application();
                app.Run(new MainWindow());
            }
            finally { mutex.ReleaseMutex(); }
        }
    }

    // ================= FPS / PERFORMANCE OVERLAY =================
    // ================= FPS OVERLAY v3: smoothed FPS + 1% low =================
    public class OverlayWindow : Window
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX b);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        struct MEMORYSTATUSEX
        {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile,
                         ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }

        // exposed so the session tracker can sample us
        public static OverlayWindow Current;
        public double SmoothFps = -1;
        public double OnePctLow = -1;

        private int frames;
        private double disp = -1;
        private List<double> history = new List<double>();  // last 60s of half-second samples
        private TextBlock txtFps, txtLow, txtCpu, txtRam;
        private Border accentBar;
        private DispatcherTimer timer;
        private PerformanceCounter cpu;

        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }

        public OverlayWindow()
        {
            Current = this;
            Width = 330; Height = 56;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            Left = SystemParameters.WorkArea.Width - Width - 24; Top = 24;

            Border card = new Border();
            card.CornerRadius = new CornerRadius(13);
            card.BorderThickness = new Thickness(1);
            card.BorderBrush = BrushH("#2A3752");
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(0, 1);
            bg.GradientStops.Add(new GradientStop(Hex("#F20A0F1C"), 0.0));
            bg.GradientStops.Add(new GradientStop(Hex("#F2131C30"), 1.0));
            card.Background = bg;
            DropShadowEffect sh = new DropShadowEffect();
            sh.BlurRadius = 18; sh.ShadowDepth = 0; sh.Opacity = 0.65; sh.Color = Colors.Black;
            card.Effect = sh;
            Content = card;

            StackPanel row = new StackPanel();
            row.Orientation = Orientation.Horizontal;
            row.HorizontalAlignment = HorizontalAlignment.Center;
            row.VerticalAlignment = VerticalAlignment.Center;
            card.Child = row;

            // gold accent bar (turns green/amber/red with performance)
            accentBar = new Border();
            accentBar.Width = 4; accentBar.Height = 28;
            accentBar.CornerRadius = new CornerRadius(2);
            accentBar.Background = BrushH("#F5C24B");
            accentBar.Margin = new Thickness(2, 0, 4, 0);
            accentBar.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(accentBar);

            txtFps = Metric(row, "FPS", "#F5C24B", 20);
            Sep(row); txtLow = Metric(row, "1% LOW", "#8A94A8", 14);
            Sep(row); txtCpu = Metric(row, "CPU", "#7C8CFF", 14);
            Sep(row); txtRam = Metric(row, "RAM", "#4ADE80", 14);

            MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };

            // invisible spinner forces WPF to render every composition frame
            Rectangle spin = new Rectangle();
            spin.Width = 1; spin.Height = 1; spin.Fill = Brushes.Transparent;
            RotateTransform rot = new RotateTransform();
            spin.RenderTransform = rot;
            row.Children.Add(spin);
            DoubleAnimation anim = new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(1)));
            anim.RepeatBehavior = RepeatBehavior.Forever;
            rot.BeginAnimation(RotateTransform.AngleProperty, anim);

            CompositionTarget.Rendering += delegate { frames++; };
            try { cpu = new PerformanceCounter("Processor", "% Processor Time", "_Total"); cpu.NextValue(); }
            catch { cpu = null; }

            // half-second ticks: smoother updates, steadier number
            timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromMilliseconds(500);
            int half = 0;
            timer.Tick += delegate
            {
                double inst = frames * 2.0; frames = 0;
                history.Add(inst);
                if (history.Count > 120) history.RemoveAt(0);   // keep 60s
                disp = (disp < 0) ? inst : (disp * 0.6 + inst * 0.4);  // exponential smoothing
                SmoothFps = disp;
                int fpsInt = (int)Math.Round(disp);
                txtFps.Text = fpsInt.ToString();

                // color-code by performance
                string c = (fpsInt >= 60) ? "#4ADE80" : (fpsInt >= 30) ? "#FBBF24" : "#FB7185";
                txtFps.Foreground = BrushH(c);
                accentBar.Background = BrushH(c);

                // 1% low over the last minute
                if (history.Count >= 20)
                {
                    List<double> sorted = new List<double>(history);
                    sorted.Sort();
                    int idx = history.Count / 100; if (idx < 0) idx = 0;
                    OnePctLow = sorted[idx];
                    txtLow.Text = ((int)Math.Round(OnePctLow)).ToString();
                }
                else { txtLow.Text = "--"; OnePctLow = -1; }

                half++;
                if (half % 2 == 0)   // CPU/RAM once per second is plenty
                {
                    if (cpu != null) { try { txtCpu.Text = ((int)cpu.NextValue()).ToString() + "%"; } catch { } }
                    MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
                    mem.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                    if (GlobalMemoryStatusEx(ref mem))
                    {
                        double used = (mem.ullTotalPhys - mem.ullAvailPhys) / 1073741824.0;
                        txtRam.Text = used.ToString("0.0") + "G";
                    }
                }
            };
            timer.Start();
            Closed += delegate { timer.Stop(); Current = null; };
        }

        private TextBlock Metric(StackPanel row, string label, string color, double size)
        {
            StackPanel col = new StackPanel();
            col.VerticalAlignment = VerticalAlignment.Center;
            col.Margin = new Thickness(9, 0, 0, 0);
            TextBlock lbl = new TextBlock();
            lbl.Text = label; lbl.FontSize = 7.5; lbl.FontWeight = FontWeights.Bold;
            lbl.Foreground = BrushH("#5B667A");
            lbl.HorizontalAlignment = HorizontalAlignment.Center;
            col.Children.Add(lbl);
            TextBlock val = new TextBlock();
            val.Text = "--"; val.FontSize = size; val.FontWeight = FontWeights.Bold;
            val.Foreground = BrushH(color);
            val.HorizontalAlignment = HorizontalAlignment.Center;
            val.Margin = new Thickness(0, -1, 0, 0);
            col.Children.Add(val);
            row.Children.Add(col);
            return val;
        }
        private void Sep(StackPanel row)
        {
            Border b = new Border();
            b.Width = 1; b.Height = 20;
            b.Background = BrushH("#232C40");
            b.Margin = new Thickness(9, 0, 0, 0);
            b.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(b);
        }
    }

    // ========================= MAIN WINDOW =========================
    public class MainWindow : Window
    {
        private List<GameEntry> games = new List<GameEntry>();
        private StackPanel listPanel;
        private TextBlock subtitle, totalTime;
        private TextBox searchBox;
        private OverlayWindow overlay;
        private Border fpsBtn; private TextBlock fpsBtnTxt;
        private DispatcherTimer trackTimer;
        private int saveCountdown = 12;
        private WinForms.NotifyIcon tray;
        private bool reallyExit = false;
        private bool balloonShown = false;
        private bool skipSaveOnExit = false;   // set after a restore so we don't overwrite it

        // ---- idle guard (v3.4): true system-wide last input ----
        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        private const int IdleLimitSec = 600;   // 10 min without input = AFK
        private bool wasIdle = false;

        // ---- session goal (v3.4) ----
        private int goalMinutes = 0;            // 0 = off
        private HashSet<string> goalWarned = new HashSet<string>();

        // ---- global hotkey Ctrl+Shift+F (v3.4) ----
        [DllImport("user32.dll")]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        private const int HOTKEY_ID = 0x3D34;

        private static double IdleSeconds()
        {
            try
            {
                LASTINPUTINFO li = new LASTINPUTINFO();
                li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
                if (!GetLastInputInfo(ref li)) return 0;
                return (Environment.TickCount - (int)li.dwTime) / 1000.0;
            }
            catch { return 0; }
        }

        // ---- session tracking ----
        private class LiveSession
        {
            public DateTime Start; public long Secs; public int Missed;
            public double FpsSum; public int FpsN; public double LowWorst;
            public double CpuSum; public int CpuN;
        }
        private Dictionary<string, LiveSession> live = new Dictionary<string, LiveSession>();
        private List<SessionEntry> sessions = new List<SessionEntry>();
        private PerformanceCounter cpuAll;
        private int sortMode = 0;   // 0 = recent, 1 = most played, 2 = A-Z
        private string wrappedDone = "";   // yyyy-MM of the last month-recap check
        private static readonly string[] SortNames = { "RECENT", "MOST PLAYED", "A-Z" };
        private TextBlock sortTxt;

        private static string DataDir
        { get { return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GameDock"); } }
        private static string DataFile { get { return System.IO.Path.Combine(DataDir, "games2.txt"); } }
        private static string SessFile { get { return System.IO.Path.Combine(DataDir, "sessions.txt"); } }
        private static string SettingsFile { get { return System.IO.Path.Combine(DataDir, "settings.txt"); } }
        private static string V1File { get { return System.IO.Path.Combine(DataDir, "games.txt"); } }

        private static readonly string[] Accents = new string[] {
            "#F5C24B", "#7C8CFF", "#4ADE80", "#F472B6", "#38BDF8", "#FB7185", "#A78BFA", "#FBBF24" };

        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }
        private static RowDefinition RowAuto() { RowDefinition r = new RowDefinition(); r.Height = GridLength.Auto; return r; }
        private static ColumnDefinition ColAuto() { ColumnDefinition c = new ColumnDefinition(); c.Width = GridLength.Auto; return c; }

        public MainWindow()
        {
            Title = "GameDock";
            Width = 460; Height = 640;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;

            Border card = new Border();
            card.CornerRadius = new CornerRadius(24);
            card.Margin = new Thickness(14);
            card.BorderThickness = new Thickness(1);
            card.BorderBrush = BrushH("#1C2740");
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(0.9, 1);
            bg.GradientStops.Add(new GradientStop(Hex("#04070F"), 0.0));
            bg.GradientStops.Add(new GradientStop(Hex("#0A111F"), 0.55));
            bg.GradientStops.Add(new GradientStop(Hex("#0E1830"), 1.0));
            card.Background = bg;
            DropShadowEffect shadow = new DropShadowEffect();
            shadow.BlurRadius = 30; shadow.ShadowDepth = 0; shadow.Opacity = 0.7; shadow.Color = Colors.Black;
            card.Effect = shadow;
            Content = card;

            Grid root = new Grid();
            root.Margin = new Thickness(24, 20, 24, 22);
            root.RowDefinitions.Add(RowAuto());   // title
            root.RowDefinitions.Add(RowAuto());   // search
            root.RowDefinitions.Add(RowAuto());   // subtitle row
            root.RowDefinitions.Add(new RowDefinition()); // list
            root.RowDefinitions.Add(RowAuto());   // add button

            // ---- layered background: warm gold glow rising from the bottom-right ----
            Grid layers = new Grid();

            Border goldGlow = new Border();
            goldGlow.CornerRadius = new CornerRadius(24);
            RadialGradientBrush glowBrush = new RadialGradientBrush();
            glowBrush.Center = new Point(0.85, 1.05);
            glowBrush.GradientOrigin = new Point(0.85, 1.05);
            glowBrush.RadiusX = 0.95; glowBrush.RadiusY = 0.85;
            glowBrush.GradientStops.Add(new GradientStop(Hex("#46F5C24B"), 0.0));
            glowBrush.GradientStops.Add(new GradientStop(Hex("#1FF5C24B"), 0.45));
            glowBrush.GradientStops.Add(new GradientStop(Hex("#00F5C24B"), 1.0));
            goldGlow.Background = glowBrush;
            goldGlow.IsHitTestVisible = false;
            layers.Children.Add(goldGlow);

            Border blueGlow = new Border();
            blueGlow.CornerRadius = new CornerRadius(24);
            RadialGradientBrush blueBrush = new RadialGradientBrush();
            blueBrush.Center = new Point(0.08, -0.05);
            blueBrush.GradientOrigin = new Point(0.08, -0.05);
            blueBrush.RadiusX = 0.8; blueBrush.RadiusY = 0.6;
            blueBrush.GradientStops.Add(new GradientStop(Hex("#2E4A5FB8"), 0.0));
            blueBrush.GradientStops.Add(new GradientStop(Hex("#004A5FB8"), 1.0));
            blueGlow.Background = blueBrush;
            blueGlow.IsHitTestVisible = false;
            layers.Children.Add(blueGlow);

            layers.Children.Add(root);
            card.Child = layers;

            // ---------- Title bar ----------
            Grid titleBar = new Grid();
            titleBar.Background = Brushes.Transparent;
            Grid.SetRow(titleBar, 0);
            root.Children.Add(titleBar);
            titleBar.MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };

            StackPanel titleLeft = new StackPanel();
            titleLeft.Orientation = Orientation.Horizontal;
            titleLeft.VerticalAlignment = VerticalAlignment.Center;

            // gold ring + controller mini-logo
            Grid logo = new Grid(); logo.Width = 30; logo.Height = 30;
            Ellipse ring = new Ellipse();
            ring.Width = 28; ring.Height = 28; ring.StrokeThickness = 2.4;
            LinearGradientBrush gold = new LinearGradientBrush();
            gold.StartPoint = new Point(0, 0); gold.EndPoint = new Point(1, 1);
            gold.GradientStops.Add(new GradientStop(Hex("#FFE9A8"), 0.0));
            gold.GradientStops.Add(new GradientStop(Hex("#F5C24B"), 0.5));
            gold.GradientStops.Add(new GradientStop(Hex("#B8860B"), 1.0));
            ring.Stroke = gold;
            DropShadowEffect glow = new DropShadowEffect();
            glow.BlurRadius = 12; glow.ShadowDepth = 0; glow.Opacity = 0.8; glow.Color = Hex("#F5C24B");
            ring.Effect = glow;
            TextBlock padIco = new TextBlock();
            padIco.Text = "\uD83C\uDFAE"; padIco.FontSize = 13;
            padIco.FontFamily = new FontFamily("Segoe UI Emoji");
            padIco.HorizontalAlignment = HorizontalAlignment.Center;
            padIco.VerticalAlignment = VerticalAlignment.Center;
            logo.Children.Add(ring); logo.Children.Add(padIco);
            titleLeft.Children.Add(logo);

            TextBlock name = new TextBlock();
            name.Text = "  GAMEDOCK"; name.FontSize = 16; name.FontWeight = FontWeights.Bold;
            name.Foreground = BrushH("#EFF3FB"); name.VerticalAlignment = VerticalAlignment.Center;
            titleLeft.Children.Add(name);
            TextBlock v2 = new TextBlock();
            v2.Text = " V3.4"; v2.FontSize = 10; v2.FontWeight = FontWeights.Bold;
            v2.Foreground = BrushH("#F5C24B"); v2.VerticalAlignment = VerticalAlignment.Center;
            v2.Margin = new Thickness(2, 0, 0, 6);
            titleLeft.Children.Add(v2);
            titleBar.Children.Add(titleLeft);

            StackPanel titleRight = new StackPanel();
            titleRight.Orientation = Orientation.Horizontal;
            titleRight.HorizontalAlignment = HorizontalAlignment.Right;
            titleBar.Children.Add(titleRight);

            // Stats page button
            Border statsBtn = new Border();
            statsBtn.CornerRadius = new CornerRadius(14);
            statsBtn.Padding = new Thickness(13, 5, 13, 5);
            statsBtn.Margin = new Thickness(0, 0, 8, 0);
            statsBtn.VerticalAlignment = VerticalAlignment.Center;
            statsBtn.Background = BrushH("#141D30");
            statsBtn.BorderThickness = new Thickness(1);
            statsBtn.BorderBrush = BrushH("#2A3752");
            statsBtn.Cursor = Cursors.Hand;
            TextBlock statsTxt = new TextBlock();
            statsTxt.Text = "STATS"; statsTxt.FontSize = 10; statsTxt.FontWeight = FontWeights.Bold;
            statsTxt.Foreground = BrushH("#8A94A8");
            statsBtn.Child = statsTxt;
            statsBtn.MouseEnter += delegate { statsBtn.BorderBrush = BrushH("#F5C24B"); statsTxt.Foreground = BrushH("#F5C24B"); };
            statsBtn.MouseLeave += delegate { statsBtn.BorderBrush = BrushH("#2A3752"); statsTxt.Foreground = BrushH("#8A94A8"); };
            statsBtn.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            { e.Handled = true; new StatsWindow(games, sessions, live.Count > 0).Show(); };
            titleRight.Children.Add(statsBtn);

            // FPS overlay toggle
            fpsBtn = new Border();
            fpsBtn.CornerRadius = new CornerRadius(14);
            fpsBtn.Padding = new Thickness(13, 5, 13, 5);
            fpsBtn.Margin = new Thickness(0, 0, 10, 0);
            fpsBtn.VerticalAlignment = VerticalAlignment.Center;
            fpsBtn.Background = BrushH("#141D30");
            fpsBtn.BorderThickness = new Thickness(1);
            fpsBtn.BorderBrush = BrushH("#2A3752");
            fpsBtn.Cursor = Cursors.Hand;
            fpsBtn.ToolTip = "FPS overlay - or press Ctrl+Shift+F anywhere, even in-game";
            fpsBtnTxt = new TextBlock();
            fpsBtnTxt.Text = "FPS  OFF"; fpsBtnTxt.FontSize = 10; fpsBtnTxt.FontWeight = FontWeights.Bold;
            fpsBtnTxt.Foreground = BrushH("#8A94A8");
            fpsBtn.Child = fpsBtnTxt;
            fpsBtn.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; ToggleOverlay(); };
            titleRight.Children.Add(fpsBtn);

            Border btnMin = ChromeBtn("\u2013", "#22293A");
            btnMin.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; WindowState = WindowState.Minimized; };
            titleRight.Children.Add(btnMin);
            Border btnClose = ChromeBtn("\u2715", "#E81123");
            btnClose.ToolTip = "Hide to tray - playtime keeps counting. Right-click the tray icon to exit.";
            btnClose.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; HideToTray(); };
            titleRight.Children.Add(btnClose);

            // ---------- Search ----------
            Border searchWrap = new Border();
            searchWrap.CornerRadius = new CornerRadius(19);
            searchWrap.Background = BrushH("#B8101827");
            searchWrap.BorderThickness = new Thickness(1);
            searchWrap.BorderBrush = BrushH("#1E2A44");
            searchWrap.Margin = new Thickness(0, 16, 0, 0);
            searchWrap.Padding = new Thickness(16, 9, 16, 9);
            Grid.SetRow(searchWrap, 1);
            root.Children.Add(searchWrap);

            StackPanel searchRow = new StackPanel();
            searchRow.Orientation = Orientation.Horizontal;
            searchWrap.Child = searchRow;
            TextBlock mag = new TextBlock();
            mag.Text = "\uD83D\uDD0D"; mag.FontSize = 12; mag.Margin = new Thickness(0, 0, 10, 0);
            mag.FontFamily = new FontFamily("Segoe UI Emoji");
            mag.VerticalAlignment = VerticalAlignment.Center; mag.Opacity = 0.5;
            searchRow.Children.Add(mag);
            searchBox = new TextBox();
            searchBox.Background = Brushes.Transparent;
            searchBox.BorderThickness = new Thickness(0);
            searchBox.Foreground = BrushH("#DEE6F5");
            searchBox.CaretBrush = BrushH("#F5C24B");
            searchBox.FontSize = 13; searchBox.Width = 330;
            searchBox.VerticalAlignment = VerticalAlignment.Center;
            searchBox.TextChanged += delegate { RefreshList(); };
            searchRow.Children.Add(searchBox);

            // ---------- Subtitle + total ----------
            Grid subRow = new Grid();
            subRow.Margin = new Thickness(6, 14, 4, 10);
            Grid.SetRow(subRow, 2);
            root.Children.Add(subRow);
            subtitle = new TextBlock();
            subtitle.Text = "YOUR LIBRARY";
            subtitle.FontSize = 10; subtitle.FontWeight = FontWeights.SemiBold;
            subtitle.Foreground = BrushH("#4E5A73");
            subRow.Children.Add(subtitle);
            StackPanel subRight = new StackPanel();
            subRight.Orientation = Orientation.Horizontal;
            subRight.HorizontalAlignment = HorizontalAlignment.Right;
            subRow.Children.Add(subRight);
            totalTime = new TextBlock();
            totalTime.FontSize = 10; totalTime.FontWeight = FontWeights.SemiBold;
            totalTime.Foreground = BrushH("#F5C24B");
            totalTime.VerticalAlignment = VerticalAlignment.Center;
            subRight.Children.Add(totalTime);
            Border sortBtn = new Border();
            sortBtn.CornerRadius = new CornerRadius(9);
            sortBtn.Padding = new Thickness(9, 3, 9, 3);
            sortBtn.Margin = new Thickness(10, -3, 0, -3);
            sortBtn.Background = BrushH("#141D30");
            sortBtn.BorderThickness = new Thickness(1);
            sortBtn.BorderBrush = BrushH("#2A3752");
            sortBtn.Cursor = Cursors.Hand;
            sortBtn.ToolTip = "Change how your library is sorted";
            sortTxt = new TextBlock();
            sortTxt.Text = "\u21C5 RECENT"; sortTxt.FontSize = 9; sortTxt.FontWeight = FontWeights.Bold;
            sortTxt.Foreground = BrushH("#8A94A8");
            sortBtn.Child = sortTxt;
            sortBtn.MouseEnter += delegate { sortBtn.BorderBrush = BrushH("#F5C24B"); sortTxt.Foreground = BrushH("#F5C24B"); };
            sortBtn.MouseLeave += delegate { sortBtn.BorderBrush = BrushH("#2A3752"); sortTxt.Foreground = BrushH("#8A94A8"); };
            sortBtn.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
                sortMode = (sortMode + 1) % 3;
                sortTxt.Text = "\u21C5 " + SortNames[sortMode];
                SaveSettings();
                RefreshList();
            };
            subRight.Children.Add(sortBtn);

            // ---------- List ----------
            ScrollViewer scroll = new ScrollViewer();
            scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            Grid.SetRow(scroll, 3);
            root.Children.Add(scroll);
            listPanel = new StackPanel();
            listPanel.Margin = new Thickness(0, 0, 4, 0);
            scroll.Content = listPanel;

            // ---------- Add button ----------
            Border addBtn = new Border();
            addBtn.CornerRadius = new CornerRadius(28);
            addBtn.Height = 54;
            addBtn.Margin = new Thickness(0, 16, 4, 0);
            addBtn.BorderThickness = new Thickness(1.5);
            addBtn.BorderBrush = BrushH("#2E3A55");
            addBtn.Background = BrushH("#B8101827");
            addBtn.Cursor = Cursors.Hand;
            StackPanel addRow = new StackPanel();
            addRow.Orientation = Orientation.Horizontal;
            addRow.HorizontalAlignment = HorizontalAlignment.Center;
            addRow.VerticalAlignment = VerticalAlignment.Center;
            TextBlock plus = new TextBlock();
            plus.Text = "+"; plus.FontSize = 20; plus.FontWeight = FontWeights.Bold;
            plus.Foreground = BrushH("#F5C24B"); plus.Margin = new Thickness(0, -3, 8, 0);
            TextBlock addTxt = new TextBlock();
            addTxt.Text = "Add a game"; addTxt.FontSize = 14; addTxt.FontWeight = FontWeights.SemiBold;
            addTxt.Foreground = BrushH("#AAB6D6");
            addRow.Children.Add(plus); addRow.Children.Add(addTxt);
            addBtn.Child = addRow;
            addBtn.MouseEnter += delegate { addBtn.Background = BrushH("#D018233A"); addBtn.BorderBrush = BrushH("#F5C24B"); };
            addBtn.MouseLeave += delegate { addBtn.Background = BrushH("#B8101827"); addBtn.BorderBrush = BrushH("#2E3A55"); };
            addBtn.MouseLeftButtonUp += delegate { AddGame(); };

            Border scanBtn = new Border();
            scanBtn.CornerRadius = new CornerRadius(28);
            scanBtn.Height = 54; scanBtn.Width = 96;
            scanBtn.Margin = new Thickness(10, 16, 4, 0);
            scanBtn.BorderThickness = new Thickness(1.5);
            scanBtn.BorderBrush = BrushH("#2E3A55");
            scanBtn.Background = BrushH("#B8101827");
            scanBtn.Cursor = Cursors.Hand;
            scanBtn.ToolTip = "Scan this PC for installed games (Steam, Epic, Start Menu)";
            StackPanel scanRow = new StackPanel();
            scanRow.Orientation = Orientation.Horizontal;
            scanRow.HorizontalAlignment = HorizontalAlignment.Center;
            scanRow.VerticalAlignment = VerticalAlignment.Center;
            TextBlock scanIco = new TextBlock();
            scanIco.Text = "\uD83D\uDD0D"; scanIco.FontSize = 13;
            scanIco.FontFamily = new FontFamily("Segoe UI Emoji");
            scanIco.Margin = new Thickness(0, 0, 6, 0);
            scanIco.VerticalAlignment = VerticalAlignment.Center;
            TextBlock scanTxt = new TextBlock();
            scanTxt.Text = "Scan"; scanTxt.FontSize = 13; scanTxt.FontWeight = FontWeights.SemiBold;
            scanTxt.Foreground = BrushH("#AAB6D6");
            scanTxt.VerticalAlignment = VerticalAlignment.Center;
            scanRow.Children.Add(scanIco); scanRow.Children.Add(scanTxt);
            scanBtn.Child = scanRow;
            scanBtn.MouseEnter += delegate { scanBtn.Background = BrushH("#D018233A"); scanBtn.BorderBrush = BrushH("#F5C24B"); };
            scanBtn.MouseLeave += delegate { scanBtn.Background = BrushH("#B8101827"); scanBtn.BorderBrush = BrushH("#2E3A55"); };
            scanBtn.MouseLeftButtonUp += delegate { ScanForGames(); };

            Grid addGrid = new Grid();
            addGrid.ColumnDefinitions.Add(new ColumnDefinition());
            addGrid.ColumnDefinitions.Add(ColAuto());
            Grid.SetColumn(addBtn, 0); Grid.SetColumn(scanBtn, 1);
            addGrid.Children.Add(addBtn); addGrid.Children.Add(scanBtn);
            Grid.SetRow(addGrid, 4);
            root.Children.Add(addGrid);

            LoadGames();
            LoadSessions();
            LoadSettings();
            sortTxt.Text = "\u21C5 " + SortNames[sortMode];
            RefreshList();
            try { cpuAll = new PerformanceCounter("Processor", "% Processor Time", "_Total"); cpuAll.NextValue(); }
            catch { cpuAll = null; }

            // ---------- Playtime tracker: ticks every 5s ----------
            trackTimer = new DispatcherTimer();
            trackTimer.Interval = TimeSpan.FromSeconds(5);
            trackTimer.Tick += delegate { TrackTick(); };
            trackTimer.Start();

            // ---------- monthly Wrapped: first launch of a new month ----------
            Loaded += delegate
            {
                string ym = DateTime.Today.ToString("yyyy-MM");
                if (wrappedDone == ym) return;
                wrappedDone = ym; SaveSettings();
                DateTime prev = new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1).AddMonths(-1);
                bool anyPrev = false;
                foreach (SessionEntry e in sessions)
                    if (e.Start >= prev && e.Start < prev.AddMonths(1)) { anyPrev = true; break; }
                if (anyPrev) new WrappedWindow(games, sessions, prev).Show();
            };

            // ---------- single-instance wake-up listener ----------
            SourceInitialized += delegate
            {
                System.Windows.Interop.HwndSource src =
                    (System.Windows.Interop.HwndSource)PresentationSource.FromVisual(this);
                if (src != null) src.AddHook(WndProc);
                // Ctrl+Shift+F -> toggle FPS overlay from anywhere (even in-game)
                try
                {
                    System.Windows.Interop.WindowInteropHelper h =
                        new System.Windows.Interop.WindowInteropHelper(this);
                    RegisterHotKey(h.Handle, HOTKEY_ID, 0x0002 | 0x0004, 0x46); // MOD_CONTROL|MOD_SHIFT, 'F'
                }
                catch { }
            };

            // ---------- system tray ----------
            SetupTray();
            // started by Windows at boot? go straight to the tray, silently
            foreach (string a in Environment.GetCommandLineArgs())
                if (a == "/tray")
                {
                    WindowState = WindowState.Minimized; ShowInTaskbar = false;
                    Loaded += delegate { Hide(); ShowInTaskbar = true; WindowState = WindowState.Normal; };
                    break;
                }
            Closing += delegate(object s, System.ComponentModel.CancelEventArgs e)
            {
                if (!reallyExit) { e.Cancel = true; HideToTray(); return; }
            };
            Closed += delegate
            {
                try
                {
                    System.Windows.Interop.WindowInteropHelper h2 =
                        new System.Windows.Interop.WindowInteropHelper(this);
                    UnregisterHotKey(h2.Handle, HOTKEY_ID);
                }
                catch { }
                if (!skipSaveOnExit)
                {
                    List<string> lk = new List<string>(live.Keys);
                    foreach (string k in lk) EndSession(k, live[k]);
                    live.Clear();
                    SaveGames();
                }
                if (overlay != null) { try { overlay.Close(); } catch { } }
                if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
            };
        }

        private void SetupTray()
        {
            tray = new WinForms.NotifyIcon();
            try
            {
                string ico = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "GameDock", "gamedock.ico");
                if (File.Exists(ico)) tray.Icon = new System.Drawing.Icon(ico);
                else tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(
                    Process.GetCurrentProcess().MainModule.FileName);
            }
            catch { tray.Icon = System.Drawing.SystemIcons.Application; }
            tray.Text = "GameDock - playtime tracking active";
            tray.Visible = true;

            tray.DoubleClick += delegate { ShowFromTray(); };
            WinForms.ContextMenuStrip menu = new WinForms.ContextMenuStrip();
            WinForms.ToolStripMenuItem miOpen = new WinForms.ToolStripMenuItem("Open GameDock");
            miOpen.Font = new System.Drawing.Font(miOpen.Font, System.Drawing.FontStyle.Bold);
            miOpen.Click += delegate { ShowFromTray(); };
            menu.Items.Add(miOpen);
            menu.Items.Add(new WinForms.ToolStripSeparator());
            WinForms.ToolStripMenuItem miBoot = new WinForms.ToolStripMenuItem("Start with Windows");
            miBoot.Checked = IsAutoStart();
            miBoot.Click += delegate
            {
                if (IsAutoStart()) { SetAutoStart(false); miBoot.Checked = false; }
                else { SetAutoStart(true); miBoot.Checked = true; }
            };
            menu.Items.Add(miBoot);
            WinForms.ToolStripMenuItem miGoal = new WinForms.ToolStripMenuItem("Session goal");
            int[] goalOpts = { 0, 60, 120, 180, 240 };
            string[] goalLbls = { "Off", "1 hour", "2 hours", "3 hours", "4 hours" };
            for (int gi = 0; gi < goalOpts.Length; gi++)
            {
                int val = goalOpts[gi];
                WinForms.ToolStripMenuItem it = new WinForms.ToolStripMenuItem(goalLbls[gi]);
                it.Checked = (goalMinutes == val);
                it.Click += delegate
                {
                    goalMinutes = val; goalWarned.Clear(); SaveSettings();
                    foreach (WinForms.ToolStripItem tsi in miGoal.DropDownItems)
                    {
                        WinForms.ToolStripMenuItem mi2 = tsi as WinForms.ToolStripMenuItem;
                        if (mi2 != null) mi2.Checked = (mi2.Text == goalLbls[Array.IndexOf(goalOpts, goalMinutes)]);
                    }
                };
                miGoal.DropDownItems.Add(it);
            }
            menu.Items.Add(miGoal);
            menu.Items.Add(new WinForms.ToolStripSeparator());
            WinForms.ToolStripMenuItem miBackup = new WinForms.ToolStripMenuItem("Backup data to Desktop");
            miBackup.Click += delegate { DoBackup(); };
            menu.Items.Add(miBackup);
            WinForms.ToolStripMenuItem miRestore = new WinForms.ToolStripMenuItem("Restore from backup...");
            miRestore.Click += delegate { DoRestore(); };
            menu.Items.Add(miRestore);
            menu.Items.Add(new WinForms.ToolStripSeparator());
            WinForms.ToolStripMenuItem miExit = new WinForms.ToolStripMenuItem("Exit (stop tracking)");
            miExit.Click += delegate { reallyExit = true; Close(); };
            menu.Items.Add(miExit);
            tray.ContextMenuStrip = menu;
        }

        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private bool IsAutoStart()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
                    return k != null && k.GetValue("GameDock") != null;
            }
            catch { return false; }
        }
        private void SetAutoStart(bool on)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return;
                    if (on)
                        k.SetValue("GameDock", "\"" + Process.GetCurrentProcess().MainModule.FileName + "\" /tray");
                    else
                        k.DeleteValue("GameDock", false);
                }
            }
            catch { }
        }

        private void DoBackup()
        {
            try
            {
                SaveGames(); SaveSettings();
                string dir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "GameDock-Backup-" + DateTime.Now.ToString("yyyyMMdd-HHmm"));
                Directory.CreateDirectory(dir);
                string[] names = { "games2.txt", "sessions.txt", "settings.txt" };
                int n = 0;
                foreach (string f in names)
                {
                    string src = System.IO.Path.Combine(DataDir, f);
                    if (File.Exists(src)) { File.Copy(src, System.IO.Path.Combine(dir, f), true); n++; }
                }
                MessageBox.Show("Backed up " + n + " file(s) to:\n\n" + dir +
                    "\n\nKeep that folder safe - it holds your playtime, sessions and settings.",
                    "GameDock", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Backup failed: " + ex.Message, "GameDock",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void DoRestore()
        {
            WinForms.FolderBrowserDialog fb = new WinForms.FolderBrowserDialog();
            fb.Description = "Pick a GameDock-Backup folder";
            if (fb.ShowDialog() != WinForms.DialogResult.OK) return;
            try
            {
                string src = fb.SelectedPath;
                if (!File.Exists(System.IO.Path.Combine(src, "games2.txt")))
                {
                    MessageBox.Show("That folder doesn't look like a GameDock backup (no games2.txt inside).",
                        "GameDock", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                if (MessageBox.Show("Restore this backup? Your CURRENT data will be replaced.",
                    "GameDock", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                Directory.CreateDirectory(DataDir);
                string[] names = { "games2.txt", "sessions.txt", "settings.txt" };
                foreach (string f in names)
                {
                    string p = System.IO.Path.Combine(src, f);
                    if (File.Exists(p)) File.Copy(p, System.IO.Path.Combine(DataDir, f), true);
                }
                skipSaveOnExit = true; reallyExit = true;
                MessageBox.Show("Backup restored! GameDock will now close - just open it again.",
                    "GameDock", MessageBoxButton.OK, MessageBoxImage.Information);
                Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Restore failed: " + ex.Message, "GameDock",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void HideToTray()
        {
            Hide();
            if (tray != null && !balloonShown)
            {
                balloonShown = true;
                SaveSettings();
                try
                {
                    tray.BalloonTipTitle = "GameDock is still running";
                    tray.BalloonTipText = "Playtime keeps counting. Double-click the tray icon to open, right-click to exit.";
                    tray.ShowBalloonTip(2500);
                }
                catch { }
            }
        }

        private void ShowFromTray()
        {
            Show();
            WindowState = WindowState.Normal;
            Activate();
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (Program.WM_SHOWGAMEDOCK != 0 && msg == (int)Program.WM_SHOWGAMEDOCK)
            {
                ShowFromTray();
                handled = true;
            }
            if (msg == 0x0312 && wParam.ToInt32() == HOTKEY_ID)   // WM_HOTKEY
            {
                ToggleOverlay();
                handled = true;
            }
            return IntPtr.Zero;
        }

        private Border ChromeBtn(string glyph, string hover)
        {
            Border b = new Border();
            b.Width = 30; b.Height = 30;
            b.CornerRadius = new CornerRadius(9);
            b.Background = Brushes.Transparent; b.Cursor = Cursors.Hand;
            TextBlock t = new TextBlock();
            t.Text = glyph; t.FontSize = 12; t.Foreground = BrushH("#8A94A8");
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            b.Child = t;
            b.MouseEnter += delegate { b.Background = BrushH(hover); t.Foreground = Brushes.White; };
            b.MouseLeave += delegate { b.Background = Brushes.Transparent; t.Foreground = BrushH("#8A94A8"); };
            return b;
        }

        private void ToggleOverlay()
        {
            if (overlay == null)
            {
                overlay = new OverlayWindow();
                overlay.Closed += delegate { overlay = null; SetFpsBtn(false); };
                overlay.Show();
                SetFpsBtn(true);
            }
            else { overlay.Close(); }
        }
        private void SetFpsBtn(bool on)
        {
            if (on)
            {
                fpsBtnTxt.Text = "FPS  ON"; fpsBtnTxt.Foreground = BrushH("#0B0F17");
                fpsBtn.Background = BrushH("#F5C24B"); fpsBtn.BorderBrush = BrushH("#F5C24B");
            }
            else
            {
                fpsBtnTxt.Text = "FPS  OFF"; fpsBtnTxt.Foreground = BrushH("#8A94A8");
                fpsBtn.Background = BrushH("#141D30"); fpsBtn.BorderBrush = BrushH("#2A3752");
            }
        }

        // ------------- playtime -------------
        // launcher exe -> the process that actually runs the game
        private static readonly Dictionary<string, string[]> Aliases =
            new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            { "RobloxPlayerLauncher", new string[] { "RobloxPlayerBeta" } },
            { "RobloxPlayerInstaller", new string[] { "RobloxPlayerBeta" } },
            { "Roblox", new string[] { "RobloxPlayerBeta" } },
            { "MinecraftLauncher", new string[] { "javaw", "Minecraft.Windows" } },
            { "Minecraft", new string[] { "javaw", "Minecraft.Windows" } },
            { "FortniteLauncher", new string[] { "FortniteClient-Win64-Shipping" } },
            { "Fortnite", new string[] { "FortniteClient-Win64-Shipping" } },
            { "GTAV", new string[] { "GTA5" } },
            { "LeagueOfLegends", new string[] { "League of Legends" } }
        };

        private List<string> TrackCandidates(GameEntry g)
        {
            List<string> c = new List<string>();
            if (g.TrackName != null && g.TrackName.Length > 0) { c.Add(g.TrackName); return c; }
            string[] extra;
            if (g.ExeName != null)
            {
                c.Add(g.ExeName);
                if (Aliases.TryGetValue(g.ExeName, out extra))
                    foreach (string x in extra) if (!c.Contains(x)) c.Add(x);
            }
            // guess from the display name: "Forza Horizon 6" -> "ForzaHorizon6"
            string guess = System.Text.RegularExpressions.Regex.Replace(g.Name, "[^A-Za-z0-9]", "");
            if (guess.Length >= 4 && !c.Contains(guess)) c.Add(guess);
            if (Aliases.TryGetValue(guess, out extra))
                foreach (string x in extra) if (!c.Contains(x)) c.Add(x);
            return c;
        }

        private void TrackTick()
        {
            bool any = false;
            bool uiDirty = false;
            double cpuNow = -1;

            // ---- idle guard: user AFK 10+ min? freeze all counting ----
            bool idle = IdleSeconds() >= IdleLimitSec;
            if (idle != wasIdle)
            {
                wasIdle = idle;
                if (tray != null)
                    tray.Text = idle ? "GameDock - paused (you're AFK)" : "GameDock - playtime tracking active";
            }
            if (idle)
            {
                // don't count time, don't end sessions either - just hold everything
                saveCountdown--;
                if (saveCountdown <= 0) saveCountdown = 12;
                return;
            }
            if (cpuAll != null) { try { cpuNow = cpuAll.NextValue(); } catch { } }

            foreach (GameEntry g in games)
            {
                bool running = false;
                try
                {
                    foreach (string cand in TrackCandidates(g))
                        if (Process.GetProcessesByName(cand).Length > 0) { running = true; break; }
                }
                catch { }

                if (running)
                {
                    g.Seconds += 5; any = true;
                    g.LastPlayed = DateTime.Now.Ticks;
                    LiveSession s;
                    if (!live.TryGetValue(g.Name, out s))
                    {
                        s = new LiveSession();
                        s.Start = DateTime.Now; s.LowWorst = -1;
                        live[g.Name] = s;
                        g.Launches++;   // one new session = one launch
                        uiDirty = true; // light the bubble up right away
                    }
                    s.Secs += 5; s.Missed = 0;
                    OverlayWindow ov = OverlayWindow.Current;
                    if (ov != null && ov.SmoothFps > 0)
                    {
                        s.FpsSum += ov.SmoothFps; s.FpsN++;
                        if (ov.OnePctLow > 0 && (s.LowWorst < 0 || ov.OnePctLow < s.LowWorst))
                            s.LowWorst = ov.OnePctLow;
                    }
                    if (cpuNow >= 0) { s.CpuSum += cpuNow; s.CpuN++; }

                    // ---- session goal warning ----
                    if (goalMinutes > 0 && s.Secs >= (long)goalMinutes * 60 && !goalWarned.Contains(g.Name))
                    {
                        goalWarned.Add(g.Name);
                        try
                        {
                            if (tray != null)
                            {
                                tray.BalloonTipTitle = "\u23F0 Session goal reached";
                                tray.BalloonTipText = g.Name + ": you've been playing " +
                                    (s.Secs / 3600 > 0 ? (s.Secs / 3600) + "h " : "") + ((s.Secs % 3600) / 60) +
                                    "m. Maybe stretch those legs, sir?";
                                tray.ShowBalloonTip(4000);
                            }
                        }
                        catch { }
                    }
                }
                else if (live.ContainsKey(g.Name))
                {
                    LiveSession s = live[g.Name];
                    s.Missed++;
                    if (s.Missed >= 3)   // 15s grace: survives brief crashes/restarts
                    {
                        EndSession(g.Name, s);
                        live.Remove(g.Name);
                        goalWarned.Remove(g.Name);
                        uiDirty = true; // glow off
                    }
                }
            }
            if (uiDirty) RefreshList();
            saveCountdown--;
            if (saveCountdown <= 0) { saveCountdown = 12; if (any) { SaveGames(); RefreshList(); } }
        }

        private void EndSession(string game, LiveSession s)
        {
            if (s.Secs < 60) return;   // ignore blips under a minute
            SessionEntry e = new SessionEntry();
            e.Game = game; e.Start = s.Start; e.Seconds = s.Secs;
            e.AvgFps = (s.FpsN > 0) ? (int)Math.Round(s.FpsSum / s.FpsN) : -1;
            e.LowFps = (s.LowWorst > 0) ? (int)Math.Round(s.LowWorst) : -1;
            e.AvgCpu = (s.CpuN > 0) ? (int)Math.Round(s.CpuSum / s.CpuN) : -1;
            sessions.Add(e);
            try
            {
                Directory.CreateDirectory(DataDir);
                File.AppendAllText(SessFile,
                    e.Game + "\t" + e.Start.ToString("yyyy-MM-dd HH:mm") + "\t" + e.Seconds +
                    "\t" + e.AvgFps + "\t" + e.LowFps + "\t" + e.AvgCpu + Environment.NewLine);
            }
            catch { }
        }

        private void LoadSettings()
        {
            try
            {
                if (!File.Exists(SettingsFile)) return;
                foreach (string line in File.ReadAllLines(SettingsFile))
                {
                    string[] p = line.Split('=');
                    if (p.Length != 2) continue;
                    if (p[0] == "sort") { int v; if (int.TryParse(p[1], out v) && v >= 0 && v <= 2) sortMode = v; }
                    if (p[0] == "balloonshown" && p[1] == "1") balloonShown = true;
                    if (p[0] == "wrapped") wrappedDone = p[1];
                    if (p[0] == "goal") { int v; if (int.TryParse(p[1], out v) && v >= 0) goalMinutes = v; }
                }
            }
            catch { }
        }

        private void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                File.WriteAllLines(SettingsFile, new string[] {
                    "sort=" + sortMode,
                    "balloonshown=" + (balloonShown ? "1" : "0"),
                    "wrapped=" + wrappedDone,
                    "goal=" + goalMinutes });
            }
            catch { }
        }

        private void RewriteSessions()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                List<string> ls = new List<string>();
                foreach (SessionEntry e in sessions)
                    ls.Add(e.Game + "\t" + e.Start.ToString("yyyy-MM-dd HH:mm") + "\t" + e.Seconds +
                           "\t" + e.AvgFps + "\t" + e.LowFps + "\t" + e.AvgCpu);
                File.WriteAllLines(SessFile, ls.ToArray());
            }
            catch { }
        }

        private void LoadSessions()
        {
            try
            {
                if (!File.Exists(SessFile)) return;
                foreach (string line in File.ReadAllLines(SessFile))
                {
                    string[] p = line.Split('\t');
                    if (p.Length < 3) continue;
                    SessionEntry e = new SessionEntry();
                    e.Game = p[0];
                    DateTime st;
                    if (!DateTime.TryParseExact(p[1], "yyyy-MM-dd HH:mm",
                        System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.None, out st)) continue;
                    e.Start = st;
                    long secs; if (!long.TryParse(p[2], out secs)) continue;
                    e.Seconds = secs;
                    int v;
                    e.AvgFps = (p.Length > 3 && int.TryParse(p[3], out v)) ? v : -1;
                    e.LowFps = (p.Length > 4 && int.TryParse(p[4], out v)) ? v : -1;
                    e.AvgCpu = (p.Length > 5 && int.TryParse(p[5], out v)) ? v : -1;
                    sessions.Add(e);
                }
            }
            catch { }
        }

        private static string Ago(long ticks)
        {
            TimeSpan d = DateTime.Now - new DateTime(ticks);
            if (d.TotalMinutes < 1) return "playing now";
            if (d.TotalMinutes < 60) return (int)d.TotalMinutes + "m ago";
            if (d.TotalHours < 24) return (int)d.TotalHours + "h ago";
            if (d.TotalDays < 2) return "yesterday";
            if (d.TotalDays < 30) return (int)d.TotalDays + " days ago";
            return new DateTime(ticks).ToString("d MMM");
        }

        private static string FormatTime(long s)
        {
            if (s < 60) return "not played yet";
            long h = s / 3600, m = (s % 3600) / 60;
            if (h > 0) return h + "h " + m + "m played";
            return m + "m played";
        }

        private string ResolveExeName(string path)
        {
            try
            {
                string target = path;
                if (path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) target = ResolveLnk(path);
                if (target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    return System.IO.Path.GetFileNameWithoutExtension(target);
            }
            catch { }
            return null;
        }

        // ------------- storage -------------
        private void LoadGames()
        {
            games.Clear();
            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
                string file = File.Exists(DataFile) ? DataFile : (File.Exists(V1File) ? V1File : null);
                if (file == null) return;
                foreach (string line in File.ReadAllLines(file))
                {
                    string[] parts = line.Split('\t');
                    if (parts.Length < 2) continue;
                    string n = parts[0].Trim(), p = parts[1].Trim();
                    if (n.Length == 0 || p.Length == 0) continue;
                    GameEntry g = new GameEntry();
                    g.Name = n; g.Path = p;
                    if (parts.Length >= 3) { long v; if (long.TryParse(parts[2], out v)) g.Seconds = v; }
                    if (parts.Length >= 4 && parts[3].Trim().Length > 0) g.TrackName = parts[3].Trim();
                    if (parts.Length >= 5) { int v2i; if (int.TryParse(parts[4], out v2i)) g.Launches = v2i; }
                    if (parts.Length >= 6) { long v2l; if (long.TryParse(parts[5], out v2l)) g.LastPlayed = v2l; }
                    g.ExeName = ResolveExeName(p);
                    games.Add(g);
                }
                if (file == V1File) SaveGames(); // migrate v1 -> v2
            }
            catch { }
        }

        private void SaveGames()
        {
            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
                List<string> lines = new List<string>();
                foreach (GameEntry g in games)
                    lines.Add(g.Name + "\t" + g.Path + "\t" + g.Seconds + "\t" + (g.TrackName == null ? "" : g.TrackName)
                        + "\t" + g.Launches + "\t" + g.LastPlayed);
                File.WriteAllLines(DataFile, lines.ToArray());
            }
            catch { }
        }

        // ------------- list UI -------------
        private void RefreshList()
        {
            listPanel.Children.Clear();
            string q = (searchBox == null) ? "" : searchBox.Text.Trim().ToLower();
            List<GameEntry> shown = new List<GameEntry>();
            foreach (GameEntry g in games)
                if (q.Length == 0 || g.Name.ToLower().Contains(q)) shown.Add(g);

            if (sortMode == 0)      // recently played first; never-played keep add order at the end
                shown.Sort(delegate(GameEntry a, GameEntry b) { return b.LastPlayed.CompareTo(a.LastPlayed); });
            else if (sortMode == 1) // most played
                shown.Sort(delegate(GameEntry a, GameEntry b) { return b.Seconds.CompareTo(a.Seconds); });
            else                    // A-Z
                shown.Sort(delegate(GameEntry a, GameEntry b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });

            if (shown.Count == 0)
            {
                TextBlock empty = new TextBlock();
                empty.Text = (games.Count == 0)
                    ? "No games yet - hit  +  below to add your first one"
                    : "No games match your search";
                empty.FontSize = 12.5; empty.Foreground = BrushH("#4E5A73");
                empty.HorizontalAlignment = HorizontalAlignment.Center;
                empty.Margin = new Thickness(0, 46, 0, 0);
                listPanel.Children.Add(empty);
            }
            else
            {
                int i = 0;
                foreach (GameEntry g in shown) { listPanel.Children.Add(MakeBubble(g, i)); i++; }
            }
            subtitle.Text = "YOUR LIBRARY  -  " + games.Count + (games.Count == 1 ? " GAME" : " GAMES");
            long total = 0; foreach (GameEntry g in games) total += g.Seconds;
            long th = total / 3600, tm = (total % 3600) / 60;
            totalTime.Text = (total < 60) ? "" : ("\u23F1 " + th + "h " + tm + "m total");
        }

        private Border MakeBubble(GameEntry game, int index)
        {
            string accent = Accents[index % Accents.Length];

            Border bubble = new Border();
            bubble.CornerRadius = new CornerRadius(30);
            bubble.Height = 62;
            bubble.Margin = new Thickness(0, 0, 0, 10);
            bubble.Background = BrushH("#CC131C2E");
            bubble.BorderThickness = new Thickness(1);
            bubble.BorderBrush = BrushH("#1B2740");
            bubble.Cursor = Cursors.Hand;

            Grid grid = new Grid();
            grid.Margin = new Thickness(9, 0, 12, 0);
            grid.ColumnDefinitions.Add(ColAuto());
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(ColAuto());
            grid.ColumnDefinitions.Add(ColAuto());
            grid.ColumnDefinitions.Add(ColAuto());
            bubble.Child = grid;

            Border chip = new Border();
            chip.Width = 44; chip.Height = 44;
            chip.CornerRadius = new CornerRadius(22);
            chip.VerticalAlignment = VerticalAlignment.Center;
            chip.Background = BrushH(accent);
            ImageSource ico = GetIcon(game.Path);
            if (ico != null)
            {
                Image img = new Image();
                img.Source = ico; img.Width = 26; img.Height = 26;
                img.HorizontalAlignment = HorizontalAlignment.Center;
                img.VerticalAlignment = VerticalAlignment.Center;
                chip.Child = img;
            }
            else
            {
                TextBlock letter = new TextBlock();
                letter.Text = game.Name.Substring(0, 1).ToUpper();
                letter.FontSize = 18; letter.FontWeight = FontWeights.Bold;
                letter.Foreground = BrushH("#0B0F17");
                letter.HorizontalAlignment = HorizontalAlignment.Center;
                letter.VerticalAlignment = VerticalAlignment.Center;
                chip.Child = letter;
            }
            Grid.SetColumn(chip, 0);
            grid.Children.Add(chip);

            StackPanel mid = new StackPanel();
            mid.VerticalAlignment = VerticalAlignment.Center;
            mid.Margin = new Thickness(14, 0, 8, 0);
            TextBlock nameTxt = new TextBlock();
            nameTxt.Text = game.Name;
            nameTxt.FontSize = 14; nameTxt.FontWeight = FontWeights.SemiBold;
            nameTxt.Foreground = BrushH("#E6ECF7");
            nameTxt.TextTrimming = TextTrimming.CharacterEllipsis;
            mid.Children.Add(nameTxt);
            TextBlock timeTxt = new TextBlock();
            string info = "\u23F1 " + FormatTime(game.Seconds);
            if (game.LastPlayed > 0)
                info += "  \u00B7  " + Ago(game.LastPlayed);
            if (game.Launches > 1)
                info += "  \u00B7  " + game.Launches + "x";
            timeTxt.Text = info;
            timeTxt.FontSize = 10.5;
            timeTxt.Foreground = BrushH(game.Seconds >= 60 ? "#F5C24B" : "#44506A");
            timeTxt.Margin = new Thickness(1, 2, 0, 0);
            mid.Children.Add(timeTxt);
            Grid.SetColumn(mid, 1);
            grid.Children.Add(mid);

            Border play = new Border();
            play.CornerRadius = new CornerRadius(17);
            play.Padding = new Thickness(17, 7, 17, 7);
            play.VerticalAlignment = VerticalAlignment.Center;
            play.Background = BrushH(accent);
            TextBlock playTxt = new TextBlock();
            playTxt.Text = "\u25B6"; playTxt.FontSize = 11;
            playTxt.Foreground = BrushH("#0B0F17");
            play.Child = playTxt;
            Grid.SetColumn(play, 2);
            grid.Children.Add(play);


            bool playingNow = live.ContainsKey(game.Name);
            string idleBorder = playingNow ? "#F5C24B" : "#1B2740";
            if (playingNow)
            {
                bubble.BorderBrush = BrushH("#F5C24B");
                DropShadowEffect glowFx = new DropShadowEffect();
                glowFx.BlurRadius = 18; glowFx.ShadowDepth = 0;
                glowFx.Color = Hex("#F5C24B"); glowFx.Opacity = 0.35;
                bubble.Effect = glowFx;
                DoubleAnimation pulse = new DoubleAnimation(0.15, 0.6, new Duration(TimeSpan.FromSeconds(1.2)));
                pulse.AutoReverse = true; pulse.RepeatBehavior = RepeatBehavior.Forever;
                glowFx.BeginAnimation(DropShadowEffect.OpacityProperty, pulse);
            }
            bubble.MouseEnter += delegate { bubble.Background = BrushH("#E01B2942"); bubble.BorderBrush = BrushH(accent); };
            bubble.MouseLeave += delegate { bubble.Background = BrushH("#CC131C2E"); bubble.BorderBrush = BrushH(idleBorder); };

            GameEntry captured = game;
            bubble.MouseLeftButtonUp += delegate
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(captured.Path);
                    psi.UseShellExecute = true;
                    Process.Start(psi);
                    captured.LastPlayed = DateTime.Now.Ticks;
                    SaveGames();
                }
                catch
                {
                    MessageBox.Show("Couldn't launch:\n" + captured.Path, "GameDock",
                        MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            };

            // ---------- right-click command menu (v3.3) ----------
            bubble.ToolTip = "Left-click: launch  \u00B7  Right-click: options";
            ContextMenu cm = new ContextMenu();
            bubble.ContextMenu = cm;

            MenuItem miLaunch = new MenuItem(); miLaunch.Header = "\u25B6  Launch";
            miLaunch.FontWeight = FontWeights.Bold;
            miLaunch.Click += delegate
            {
                try
                {
                    ProcessStartInfo psi2 = new ProcessStartInfo(captured.Path);
                    psi2.UseShellExecute = true; Process.Start(psi2);
                    captured.LastPlayed = DateTime.Now.Ticks; SaveGames();
                }
                catch { }
            };
            cm.Items.Add(miLaunch);
            cm.Items.Add(new Separator());

            MenuItem miRen = new MenuItem(); miRen.Header = "\u270E  Rename";
            miRen.Click += delegate
            {
                NameDialog rd = new NameDialog(captured.Name, "Rename this game:");
                rd.Owner = this;
                if (rd.ShowDialog() == true && rd.Value != null && rd.Value.Trim().Length > 0)
                {
                    string nn = rd.Value.Trim();
                    string oldN = captured.Name;
                    if (nn == oldN) return;
                    // keep session history and any live session attached to the new name
                    foreach (SessionEntry se in sessions) if (se.Game == oldN) se.Game = nn;
                    RewriteSessions();
                    if (live.ContainsKey(oldN)) { live[nn] = live[oldN]; live.Remove(oldN); }
                    captured.Name = nn;
                    SaveGames(); RefreshList();
                }
            };
            cm.Items.Add(miRen);

            MenuItem miTrack = new MenuItem(); miTrack.Header = "\u2699  Set tracked process...";
            miTrack.Click += delegate
            {
                string cur = (captured.TrackName != null) ? captured.TrackName
                           : ((captured.ExeName != null) ? captured.ExeName : "");
                NameDialog nd = new NameDialog(cur,
                    "Process to track for playtime - open Task Manager > Details while the game runs, type its name without .exe (leave empty for auto):");
                nd.Owner = this;
                if (nd.ShowDialog() == true)
                {
                    string v = (nd.Value == null) ? "" : nd.Value.Trim();
                    if (v.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) v = v.Substring(0, v.Length - 4);
                    captured.TrackName = (v.Length == 0) ? null : v;
                    SaveGames(); RefreshList();
                }
            };
            cm.Items.Add(miTrack);

            MenuItem miLoc = new MenuItem(); miLoc.Header = "\uD83D\uDCC1  Open file location";
            miLoc.Click += delegate
            {
                try { Process.Start("explorer.exe", "/select,\"" + captured.Path + "\""); } catch { }
            };
            cm.Items.Add(miLoc);
            cm.Items.Add(new Separator());

            MenuItem miReset = new MenuItem(); miReset.Header = "\u21BA  Reset playtime";
            miReset.Click += delegate
            {
                if (MessageBox.Show("Reset all playtime for \"" + captured.Name + "\"?\n(Past sessions stay in Stats.)",
                    "GameDock", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                {
                    captured.Seconds = 0; captured.Launches = 0; captured.LastPlayed = 0;
                    SaveGames(); RefreshList();
                }
            };
            cm.Items.Add(miReset);

            MenuItem miDel = new MenuItem(); miDel.Header = "\u2715  Remove from dock";
            miDel.Click += delegate
            {
                if (MessageBox.Show("Remove \"" + captured.Name + "\" from GameDock?",
                    "GameDock", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                {
                    games.Remove(captured);
                    SaveGames(); RefreshList();
                }
            };
            cm.Items.Add(miDel);

            return bubble;
        }

        private ImageSource GetIcon(string path)
        {
            try
            {
                string target = path;
                if (path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) target = ResolveLnk(path);
                System.Drawing.Icon icon = System.Drawing.Icon.ExtractAssociatedIcon(target);
                if (icon == null) return null;
                ImageSource src = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(
                    icon.Handle, Int32Rect.Empty,
                    System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
                src.Freeze();
                return src;
            }
            catch { return null; }
        }

        private string ResolveLnk(string path)
        {
            try
            {
                Type t = Type.GetTypeFromProgID("WScript.Shell");
                object sh = Activator.CreateInstance(t);
                object sc = t.InvokeMember("CreateShortcut",
                    System.Reflection.BindingFlags.InvokeMethod, null, sh, new object[] { path });
                string target = (string)sc.GetType().InvokeMember("TargetPath",
                    System.Reflection.BindingFlags.GetProperty, null, sc, null);
                if (!string.IsNullOrEmpty(target) && File.Exists(target)) return target;
            }
            catch { }
            return path;
        }

        // ---------- auto-discovery (v3.3) ----------
        private void ScanForGames()
        {
            List<GameEntry> found = new List<GameEntry>();
            HashSet<string> seenPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (GameEntry g in games) { seenPaths.Add(g.Path); seenNames.Add(g.Name); }

            // --- Steam: parse libraryfolders.vdf for all library roots ---
            try
            {
                List<string> roots = new List<string>();
                string steam = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
                if (Directory.Exists(steam)) roots.Add(steam);
                string vdf = System.IO.Path.Combine(steam, "steamapps", "libraryfolders.vdf");
                if (File.Exists(vdf))
                {
                    foreach (System.Text.RegularExpressions.Match mm in
                        System.Text.RegularExpressions.Regex.Matches(File.ReadAllText(vdf),
                        "\"path\"\\s+\"([^\"]+)\""))
                    {
                        string r = mm.Groups[1].Value.Replace("\\\\", "\\");
                        if (Directory.Exists(r) && !roots.Contains(r)) roots.Add(r);
                    }
                }
                foreach (string root in roots)
                {
                    string common = System.IO.Path.Combine(root, "steamapps", "common");
                    if (!Directory.Exists(common)) continue;
                    foreach (string dir in Directory.GetDirectories(common))
                    {
                        string name = System.IO.Path.GetFileName(dir);
                        if (name == "Steamworks Shared") continue;
                        string exe = BiggestExe(dir);
                        if (exe != null) AddFound(found, seenPaths, seenNames, name, exe);
                    }
                }
            }
            catch { }

            // --- Epic Games ---
            try
            {
                string epic = System.IO.Path.Combine(
                    Environment.GetEnvironmentVariable("ProgramFiles") ?? "C:\\Program Files", "Epic Games");
                if (Directory.Exists(epic))
                    foreach (string dir in Directory.GetDirectories(epic))
                    {
                        string name = System.IO.Path.GetFileName(dir);
                        if (name.StartsWith("Launcher", StringComparison.OrdinalIgnoreCase)) continue;
                        string exe = BiggestExe(dir);
                        if (exe != null) AddFound(found, seenPaths, seenNames, name, exe);
                    }
            }
            catch { }

            // --- Start Menu shortcuts that point at exes in game-ish folders ---
            try
            {
                string[] menus = {
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
                    Environment.GetFolderPath(Environment.SpecialFolder.StartMenu) };
                string[] hints = { "steam", "epic", "games", "riot", "blizzard", "ubisoft", "ea games", "gog" };
                string[] skip = { "uninstall", "readme", "manual", "website", "support", "settings",
                                  "config", "editor", "server", "launcher help", "crash", "report" };
                foreach (string menu in menus)
                {
                    if (menu == null || !Directory.Exists(menu)) continue;
                    foreach (string lnk in Directory.GetFiles(menu, "*.lnk", SearchOption.AllDirectories))
                    {
                        string nm = System.IO.Path.GetFileNameWithoutExtension(lnk);
                        string low = nm.ToLower();
                        bool bad = false;
                        foreach (string s in skip) if (low.Contains(s)) { bad = true; break; }
                        if (bad) continue;
                        string target = ResolveLnk(lnk);
                        if (target == lnk || !target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                        if (!File.Exists(target)) continue;
                        string tl = target.ToLower();
                        bool gamey = false;
                        foreach (string h in hints) if (tl.Contains(h)) { gamey = true; break; }
                        if (!gamey) continue;
                        AddFound(found, seenPaths, seenNames, nm, target);
                    }
                }
            }
            catch { }

            if (found.Count == 0)
            {
                MessageBox.Show("Scan finished - no new games found.\n\n(Already-added games are skipped. Store/Xbox app games can't be found by scanning - add those with the + button.)",
                    "GameDock", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            ScanWindow sw = new ScanWindow(found);
            sw.Owner = this;
            if (sw.ShowDialog() == true)
            {
                int added = 0;
                foreach (GameEntry g in sw.Chosen)
                {
                    g.ExeName = ResolveExeName(g.Path);
                    games.Add(g); added++;
                }
                if (added > 0) { SaveGames(); RefreshList(); }
            }
        }

        private void AddFound(List<GameEntry> found, HashSet<string> seenPaths, HashSet<string> seenNames,
            string name, string path)
        {
            if (seenPaths.Contains(path) || seenNames.Contains(name)) return;
            foreach (GameEntry f in found)
                if (string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return;
            GameEntry g = new GameEntry();
            g.Name = name; g.Path = path;
            found.Add(g);
        }

        // largest exe in a game folder is nearly always the game itself
        private string BiggestExe(string dir)
        {
            try
            {
                string bestP = null; long bestS = 0;
                foreach (string exe in Directory.GetFiles(dir, "*.exe", SearchOption.AllDirectories))
                {
                    string nm = System.IO.Path.GetFileNameWithoutExtension(exe).ToLower();
                    if (nm.Contains("unins") || nm.Contains("crash") || nm.Contains("setup") ||
                        nm.Contains("redist") || nm.Contains("vcredist") || nm.Contains("dxsetup") ||
                        nm.Contains("report") || nm.Contains("eac") || nm.Contains("anticheat")) continue;
                    long sz = new FileInfo(exe).Length;
                    if (sz > bestS) { bestS = sz; bestP = exe; }
                }
                return (bestS > 3 * 1024 * 1024) ? bestP : null;   // ignore tiny stubs < 3 MB
            }
            catch { return null; }
        }

        private void AddGame()
        {
            Microsoft.Win32.OpenFileDialog dlg = new Microsoft.Win32.OpenFileDialog();
            dlg.Title = "Pick a game (.exe or shortcut)";
            dlg.Filter = "Games and shortcuts (*.exe;*.lnk;*.url)|*.exe;*.lnk;*.url|All files (*.*)|*.*";
            try { dlg.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Desktop); } catch { }
            if (dlg.ShowDialog() == true)
            {
                string def = System.IO.Path.GetFileNameWithoutExtension(dlg.FileName);
                NameDialog nd = new NameDialog(def);
                nd.Owner = this;
                string chosen = def;
                if (nd.ShowDialog() == true) chosen = nd.Value;
                if (chosen == null || chosen.Trim().Length == 0) chosen = def;
                GameEntry g = new GameEntry();
                g.Name = chosen.Trim(); g.Path = dlg.FileName;
                g.ExeName = ResolveExeName(dlg.FileName);
                games.Add(g);
                SaveGames(); RefreshList();
            }
        }
    }

    // ========================= GAMING STATS (v3.0) =========================
    public class StatsWindow : Window
    {
        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }

        private List<GameEntry> gamesRef;
        private List<SessionEntry> sessRef;

        public StatsWindow(List<GameEntry> games, List<SessionEntry> sessions, bool liveNow)
        {
            gamesRef = games; sessRef = sessions;
            Title = "Gaming Stats";
            Width = 520; Height = 700;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;

            Border card = new Border();
            card.CornerRadius = new CornerRadius(24);
            card.Margin = new Thickness(14);
            card.BorderThickness = new Thickness(1);
            card.BorderBrush = BrushH("#1C2740");
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(0.9, 1);
            bg.GradientStops.Add(new GradientStop(Hex("#04070F"), 0.0));
            bg.GradientStops.Add(new GradientStop(Hex("#0A111F"), 0.55));
            bg.GradientStops.Add(new GradientStop(Hex("#0E1830"), 1.0));
            card.Background = bg;
            DropShadowEffect shadow = new DropShadowEffect();
            shadow.BlurRadius = 30; shadow.ShadowDepth = 0; shadow.Opacity = 0.7; shadow.Color = Colors.Black;
            card.Effect = shadow;
            Content = card;

            Grid root = new Grid();
            root.Margin = new Thickness(24, 20, 24, 22);
            RowDefinition r0 = new RowDefinition(); r0.Height = GridLength.Auto;
            root.RowDefinitions.Add(r0);
            root.RowDefinitions.Add(new RowDefinition());
            card.Child = root;

            // title bar
            Grid tb = new Grid();
            tb.Background = Brushes.Transparent;
            Grid.SetRow(tb, 0);
            root.Children.Add(tb);
            tb.MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };
            StackPanel tl = new StackPanel();
            tl.Orientation = Orientation.Horizontal;
            TextBlock icon = new TextBlock();
            icon.Text = "\uD83D\uDCCA"; icon.FontSize = 16;
            icon.FontFamily = new FontFamily("Segoe UI Emoji");
            icon.VerticalAlignment = VerticalAlignment.Center;
            tl.Children.Add(icon);
            TextBlock name = new TextBlock();
            name.Text = "  GAMING STATS"; name.FontSize = 15; name.FontWeight = FontWeights.Bold;
            name.Foreground = BrushH("#EFF3FB"); name.VerticalAlignment = VerticalAlignment.Center;
            tl.Children.Add(name);
            tb.Children.Add(tl);
            StackPanel tr = new StackPanel();
            tr.Orientation = Orientation.Horizontal;
            tr.HorizontalAlignment = HorizontalAlignment.Right;
            tb.Children.Add(tr);

            Border wrapBtn = new Border();
            wrapBtn.CornerRadius = new CornerRadius(9);
            wrapBtn.Padding = new Thickness(10, 5, 10, 5);
            wrapBtn.Margin = new Thickness(0, 0, 8, 0);
            wrapBtn.Background = BrushH("#141D30");
            wrapBtn.BorderThickness = new Thickness(1);
            wrapBtn.BorderBrush = BrushH("#2A3752");
            wrapBtn.Cursor = Cursors.Hand;
            wrapBtn.ToolTip = "This month's recap";
            TextBlock wrapTxt = new TextBlock();
            wrapTxt.Text = "\uD83C\uDF81"; wrapTxt.FontSize = 12;
            wrapTxt.FontFamily = new FontFamily("Segoe UI Emoji");
            wrapBtn.Child = wrapTxt;
            wrapBtn.MouseEnter += delegate { wrapBtn.BorderBrush = BrushH("#F5C24B"); };
            wrapBtn.MouseLeave += delegate { wrapBtn.BorderBrush = BrushH("#2A3752"); };
            wrapBtn.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
                new WrappedWindow(gamesRef, sessRef,
                    new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1)).Show();
            };
            tr.Children.Add(wrapBtn);

            Border shareBtn = new Border();
            shareBtn.CornerRadius = new CornerRadius(9);
            shareBtn.Padding = new Thickness(11, 5, 11, 5);
            shareBtn.Margin = new Thickness(0, 0, 8, 0);
            shareBtn.Background = BrushH("#141D30");
            shareBtn.BorderThickness = new Thickness(1);
            shareBtn.BorderBrush = BrushH("#2A3752");
            shareBtn.Cursor = Cursors.Hand;
            shareBtn.ToolTip = "Save a shareable stats card (PNG on your Desktop)";
            TextBlock shareTxt = new TextBlock();
            shareTxt.Text = "\uD83D\uDCF8 SHARE"; shareTxt.FontSize = 10; shareTxt.FontWeight = FontWeights.Bold;
            shareTxt.FontFamily = new FontFamily("Segoe UI Emoji");
            shareTxt.Foreground = BrushH("#8A94A8");
            shareBtn.Child = shareTxt;
            shareBtn.MouseEnter += delegate { shareBtn.BorderBrush = BrushH("#F5C24B"); shareTxt.Foreground = BrushH("#F5C24B"); };
            shareBtn.MouseLeave += delegate { shareBtn.BorderBrush = BrushH("#2A3752"); shareTxt.Foreground = BrushH("#8A94A8"); };
            shareBtn.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; ShareCard(); };
            tr.Children.Add(shareBtn);

            Border x = new Border();
            x.Width = 34; x.Height = 30; x.CornerRadius = new CornerRadius(9);
            x.Background = BrushH("#141D30"); x.Cursor = Cursors.Hand;
            TextBlock xg = new TextBlock();
            xg.Text = "\u2715"; xg.FontSize = 12; xg.Foreground = BrushH("#8A94A8");
            xg.HorizontalAlignment = HorizontalAlignment.Center; xg.VerticalAlignment = VerticalAlignment.Center;
            x.Child = xg;
            x.MouseEnter += delegate { x.Background = BrushH("#E81123"); xg.Foreground = Brushes.White; };
            x.MouseLeave += delegate { x.Background = BrushH("#141D30"); xg.Foreground = BrushH("#8A94A8"); };
            x.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; Close(); };
            tr.Children.Add(x);

            ScrollViewer sc = new ScrollViewer();
            sc.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            sc.Margin = new Thickness(0, 14, 0, 0);
            Grid.SetRow(sc, 1);
            root.Children.Add(sc);
            StackPanel body = new StackPanel();
            sc.Content = body;

            // ================== compute ==================
            long totalSecs = 0;
            foreach (GameEntry g in games) totalSecs += g.Seconds;

            DateTime today = DateTime.Today;
            DateTime weekStart = today.AddDays(-(int)((today.DayOfWeek == DayOfWeek.Sunday) ? 6 : (int)today.DayOfWeek - 1));
            DateTime monthStart = new DateTime(today.Year, today.Month, 1);
            long weekSecs = 0, monthSecs = 0, prevWeekSecs = 0, prevMonthSecs = 0;
            SessionEntry longest = null;
            HashSet<DateTime> playDays = new HashSet<DateTime>();
            foreach (SessionEntry e in sessions)
            {
                if (e.Start >= weekStart) weekSecs += e.Seconds;
                else if (e.Start >= weekStart.AddDays(-7) && e.Start < weekStart) prevWeekSecs += e.Seconds;
                if (e.Start >= monthStart) { }
                else if (e.Start >= monthStart.AddMonths(-1) && e.Start < monthStart) prevMonthSecs += e.Seconds;
                if (e.Start >= monthStart) monthSecs += e.Seconds;
                if (longest == null || e.Seconds > longest.Seconds) longest = e;
                playDays.Add(e.Start.Date);
            }
            if (liveNow) playDays.Add(today);

            // current streak
            int streak = 0;
            DateTime d = today;
            if (!playDays.Contains(d)) d = d.AddDays(-1);   // today not played *yet* doesn't break it
            while (playDays.Contains(d)) { streak++; d = d.AddDays(-1); }
            // longest streak
            int best = 0;
            List<DateTime> sorted = new List<DateTime>(playDays);
            sorted.Sort();
            int run = 0; DateTime prev = DateTime.MinValue;
            foreach (DateTime pd in sorted)
            {
                run = (prev != DateTime.MinValue && (pd - prev).Days == 1) ? run + 1 : 1;
                if (run > best) best = run;
                prev = pd;
            }

            // ================== overview cards ==================
            Section(body, "OVERVIEW");
            Grid cards = new Grid();
            cards.ColumnDefinitions.Add(new ColumnDefinition());
            cards.ColumnDefinitions.Add(new ColumnDefinition());
            cards.RowDefinitions.Add(new RowDefinition());
            cards.RowDefinitions.Add(new RowDefinition());
            cards.RowDefinitions.Add(new RowDefinition());
            body.Children.Add(cards);
            StatCard(cards, 0, 0, "\uD83C\uDFAE", "Games", games.Count.ToString(), "#7C8CFF");
            StatCard(cards, 0, 1, "\u23F1", "Total Playtime", FmtHM(totalSecs), "#F5C24B");
            StatCard(cards, 1, 0, "\uD83D\uDCC5", "This Week", FmtHM(weekSecs), "#4ADE80",
                Trend(weekSecs, prevWeekSecs, "last week"));
            StatCard(cards, 1, 1, "\uD83D\uDDD3", "This Month", FmtHM(monthSecs), "#38BDF8",
                Trend(monthSecs, prevMonthSecs, "last month"));
            StatCard(cards, 2, 0, "\uD83C\uDFC6", "Longest Session",
                (longest == null) ? "--" : FmtHM(longest.Seconds), "#F472B6");
            StatCard(cards, 2, 1, "\uD83D\uDD25", "Best Streak",
                (best == 0) ? "--" : (best + (best == 1 ? " day" : " days")), "#FB7185");

            // ================== streak ==================
            Section(body, "GAMING STREAK");
            Border stCard = new Border();
            stCard.CornerRadius = new CornerRadius(18);
            stCard.Background = BrushH("#B8101827");
            stCard.BorderThickness = new Thickness(1);
            stCard.BorderBrush = BrushH("#1E2A44");
            stCard.Padding = new Thickness(18, 14, 18, 16);
            stCard.Margin = new Thickness(0, 0, 0, 4);
            body.Children.Add(stCard);
            StackPanel stCol = new StackPanel();
            stCard.Child = stCol;
            TextBlock stBig = new TextBlock();
            stBig.Text = (streak == 0) ? "No streak yet - play today to start one!"
                : "\uD83D\uDD25 " + streak + (streak == 1 ? " DAY STREAK" : " DAY STREAK");
            stBig.FontSize = (streak == 0) ? 12.5 : 18;
            stBig.FontWeight = FontWeights.Bold;
            stBig.FontFamily = new FontFamily("Segoe UI Emoji");
            stBig.Foreground = (streak == 0) ? BrushH("#8A94A8") : BrushH("#F5C24B");
            stBig.HorizontalAlignment = HorizontalAlignment.Center;
            stCol.Children.Add(stBig);
            StackPanel week = new StackPanel();
            week.Orientation = Orientation.Horizontal;
            week.HorizontalAlignment = HorizontalAlignment.Center;
            week.Margin = new Thickness(0, 12, 0, 0);
            stCol.Children.Add(week);
            string[] dayNames = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
            for (int i = 0; i < 7; i++)
            {
                DateTime day = weekStart.AddDays(i);
                bool played = playDays.Contains(day);
                bool future = day > today;
                StackPanel dc = new StackPanel();
                dc.Margin = new Thickness(6, 0, 6, 0);
                TextBlock dn = new TextBlock();
                dn.Text = dayNames[i]; dn.FontSize = 9; dn.FontWeight = FontWeights.Bold;
                dn.Foreground = BrushH("#5B667A");
                dn.HorizontalAlignment = HorizontalAlignment.Center;
                dc.Children.Add(dn);
                Border dot = new Border();
                dot.Width = 26; dot.Height = 26; dot.CornerRadius = new CornerRadius(13);
                dot.Margin = new Thickness(0, 5, 0, 0);
                dot.Background = played ? BrushH("#F5C24B") : BrushH("#141D30");
                dot.BorderThickness = new Thickness(1);
                dot.BorderBrush = played ? BrushH("#F5C24B") : BrushH("#2A3752");
                TextBlock mark = new TextBlock();
                mark.Text = played ? "\u2713" : (future ? "" : "\u2013");
                mark.FontSize = 12; mark.FontWeight = FontWeights.Bold;
                mark.Foreground = played ? BrushH("#0B0F17") : BrushH("#3A4560");
                mark.HorizontalAlignment = HorizontalAlignment.Center;
                mark.VerticalAlignment = VerticalAlignment.Center;
                dot.Child = mark;
                dc.Children.Add(dot);
                week.Children.Add(dc);
            }

            // ================== playtime by day (14 days) ==================
            Section(body, "PLAYTIME - LAST 14 DAYS");
            long[] daySecs = new long[14];
            long dayMax = 0;
            foreach (SessionEntry e in sessions)
            {
                int off = (int)(today - e.Start.Date).TotalDays;
                if (off >= 0 && off < 14) daySecs[13 - off] += e.Seconds;
            }
            foreach (long v in daySecs) if (v > dayMax) dayMax = v;
            Border chCard = new Border();
            chCard.CornerRadius = new CornerRadius(18);
            chCard.Background = BrushH("#B8101827");
            chCard.BorderThickness = new Thickness(1);
            chCard.BorderBrush = BrushH("#1E2A44");
            chCard.Padding = new Thickness(14, 14, 14, 10);
            chCard.Margin = new Thickness(0, 0, 0, 4);
            body.Children.Add(chCard);
            if (dayMax == 0)
            {
                TextBlock none = new TextBlock();
                none.Text = "No sessions recorded yet - go play something!";
                none.FontSize = 12; none.Foreground = BrushH("#8A94A8");
                none.HorizontalAlignment = HorizontalAlignment.Center;
                chCard.Child = none;
            }
            else
            {
                StackPanel bars = new StackPanel();
                bars.Orientation = Orientation.Horizontal;
                bars.HorizontalAlignment = HorizontalAlignment.Center;
                chCard.Child = bars;
                for (int i = 0; i < 14; i++)
                {
                    DateTime day = today.AddDays(i - 13);
                    StackPanel bc = new StackPanel();
                    bc.Margin = new Thickness(3.5, 0, 3.5, 0);
                    bc.VerticalAlignment = VerticalAlignment.Bottom;
                    double h = (dayMax == 0) ? 2 : 4 + 86.0 * daySecs[i] / dayMax;
                    if (daySecs[i] == 0) h = 3;
                    Border bar = new Border();
                    bar.Width = 18; bar.Height = h;
                    bar.CornerRadius = new CornerRadius(4);
                    bar.VerticalAlignment = VerticalAlignment.Bottom;
                    bar.Background = (daySecs[i] == 0) ? BrushH("#1A2438")
                        : (day == today ? BrushH("#F5C24B") : BrushH("#7C8CFF"));
                    bar.ToolTip = day.ToString("ddd d MMM") + " - " + FmtHM(daySecs[i]);
                    StackPanel wrap = new StackPanel();
                    wrap.Height = 96; wrap.VerticalAlignment = VerticalAlignment.Bottom;
                    Grid gWrap = new Grid(); gWrap.Height = 96;
                    bar.VerticalAlignment = VerticalAlignment.Bottom;
                    gWrap.Children.Add(bar);
                    bc.Children.Add(gWrap);
                    TextBlock dl = new TextBlock();
                    dl.Text = day.ToString("dd"); dl.FontSize = 8;
                    dl.Foreground = (day == today) ? BrushH("#F5C24B") : BrushH("#5B667A");
                    dl.HorizontalAlignment = HorizontalAlignment.Center;
                    dl.Margin = new Thickness(0, 4, 0, 0);
                    bc.Children.Add(dl);
                    bars.Children.Add(bc);
                }
            }

            // ================== most played ==================
            Section(body, "MOST PLAYED");
            List<GameEntry> top = new List<GameEntry>(games);
            top.Sort(delegate(GameEntry a, GameEntry b) { return b.Seconds.CompareTo(a.Seconds); });
            long topMax = (top.Count > 0) ? top[0].Seconds : 0;
            Border mpCard = new Border();
            mpCard.CornerRadius = new CornerRadius(18);
            mpCard.Background = BrushH("#B8101827");
            mpCard.BorderThickness = new Thickness(1);
            mpCard.BorderBrush = BrushH("#1E2A44");
            mpCard.Padding = new Thickness(18, 14, 18, 14);
            mpCard.Margin = new Thickness(0, 0, 0, 4);
            body.Children.Add(mpCard);
            StackPanel mpCol = new StackPanel();
            mpCard.Child = mpCol;
            string[] mpColors = { "#F5C24B", "#7C8CFF", "#4ADE80", "#F472B6", "#38BDF8" };
            if (topMax == 0)
            {
                TextBlock none2 = new TextBlock();
                none2.Text = "No playtime yet";
                none2.FontSize = 12; none2.Foreground = BrushH("#8A94A8");
                none2.HorizontalAlignment = HorizontalAlignment.Center;
                mpCol.Children.Add(none2);
            }
            else
            {
                int shown = 0;
                foreach (GameEntry g in top)
                {
                    if (g.Seconds < 60 || shown >= 5) continue;
                    Grid rowG = new Grid();
                    rowG.Margin = new Thickness(0, (shown == 0) ? 0 : 10, 0, 0);
                    ColumnDefinition c0 = new ColumnDefinition(); c0.Width = new GridLength(130);
                    rowG.ColumnDefinitions.Add(c0);
                    rowG.ColumnDefinitions.Add(new ColumnDefinition());
                    ColumnDefinition c2 = new ColumnDefinition(); c2.Width = GridLength.Auto;
                    rowG.ColumnDefinitions.Add(c2);
                    TextBlock nm = new TextBlock();
                    nm.Text = g.Name; nm.FontSize = 11.5; nm.FontWeight = FontWeights.SemiBold;
                    nm.Foreground = BrushH("#DEE6F5");
                    nm.TextTrimming = TextTrimming.CharacterEllipsis;
                    nm.VerticalAlignment = VerticalAlignment.Center;
                    Grid.SetColumn(nm, 0);
                    rowG.Children.Add(nm);
                    Border track = new Border();
                    track.Height = 9; track.CornerRadius = new CornerRadius(4.5);
                    track.Background = BrushH("#141D30");
                    track.Margin = new Thickness(8, 0, 8, 0);
                    track.VerticalAlignment = VerticalAlignment.Center;
                    Grid.SetColumn(track, 1);
                    rowG.Children.Add(track);
                    Border fill = new Border();
                    fill.Height = 9; fill.CornerRadius = new CornerRadius(4.5);
                    fill.Background = BrushH(mpColors[shown % mpColors.Length]);
                    fill.HorizontalAlignment = HorizontalAlignment.Left;
                    double frac = (double)g.Seconds / topMax;
                    fill.SetBinding(Border.WidthProperty, new System.Windows.Data.Binding("ActualWidth")
                    { Source = track, Converter = new FracConverter(), ConverterParameter = frac });
                    track.Child = null;
                    Grid trackWrap = new Grid();
                    trackWrap.Margin = new Thickness(8, 0, 8, 0);
                    trackWrap.VerticalAlignment = VerticalAlignment.Center;
                    rowG.Children.Remove(track);
                    track.Margin = new Thickness(0);
                    trackWrap.Children.Add(track);
                    fill.Margin = new Thickness(0);
                    trackWrap.Children.Add(fill);
                    Grid.SetColumn(trackWrap, 1);
                    rowG.Children.Add(trackWrap);
                    TextBlock tm = new TextBlock();
                    tm.Text = FmtHM(g.Seconds); tm.FontSize = 11; tm.FontWeight = FontWeights.Bold;
                    tm.Foreground = BrushH(mpColors[shown % mpColors.Length]);
                    tm.VerticalAlignment = VerticalAlignment.Center;
                    Grid.SetColumn(tm, 2);
                    rowG.Children.Add(tm);
                    mpCol.Children.Add(rowG);
                    shown++;
                }
            }

            // ================== recent sessions ==================
            Section(body, "RECENT SESSIONS");
            Border seCard = new Border();
            seCard.CornerRadius = new CornerRadius(18);
            seCard.Background = BrushH("#B8101827");
            seCard.BorderThickness = new Thickness(1);
            seCard.BorderBrush = BrushH("#1E2A44");
            seCard.Padding = new Thickness(18, 12, 18, 12);
            seCard.Margin = new Thickness(0, 0, 0, 8);
            body.Children.Add(seCard);
            StackPanel seCol = new StackPanel();
            seCard.Child = seCol;
            if (sessions.Count == 0)
            {
                TextBlock none3 = new TextBlock();
                none3.Text = "Sessions appear here after you play (min 1 minute).\nTip: turn the FPS overlay ON while playing to record FPS stats too.";
                none3.FontSize = 11.5; none3.Foreground = BrushH("#8A94A8");
                none3.TextWrapping = TextWrapping.Wrap;
                none3.TextAlignment = TextAlignment.Center;
                seCol.Children.Add(none3);
            }
            else
            {
                int n = 0;
                for (int i = sessions.Count - 1; i >= 0 && n < 8; i--, n++)
                {
                    SessionEntry e = sessions[i];
                    StackPanel sRow = new StackPanel();
                    sRow.Margin = new Thickness(0, (n == 0) ? 0 : 10, 0, 0);
                    Grid l1 = new Grid();
                    TextBlock gn = new TextBlock();
                    gn.Text = e.Game; gn.FontSize = 12.5; gn.FontWeight = FontWeights.Bold;
                    gn.Foreground = BrushH("#DEE6F5");
                    l1.Children.Add(gn);
                    TextBlock when = new TextBlock();
                    when.Text = SessionDay(e.Start) + "  " + e.Start.ToString("HH:mm");
                    when.FontSize = 10.5; when.Foreground = BrushH("#5B667A");
                    when.HorizontalAlignment = HorizontalAlignment.Right;
                    l1.Children.Add(when);
                    sRow.Children.Add(l1);
                    TextBlock l2 = new TextBlock();
                    string fpsPart = (e.AvgFps > 0)
                        ? "   \u00B7   " + e.AvgFps + " FPS avg" + ((e.LowFps > 0) ? "  (" + e.LowFps + " low)" : "")
                        : "";
                    string cpuPart = (e.AvgCpu >= 0) ? "   \u00B7   CPU " + e.AvgCpu + "%" : "";
                    l2.Text = "\u23F1 " + FmtHM(e.Seconds) + fpsPart + cpuPart;
                    l2.FontSize = 10.5; l2.Foreground = BrushH("#8A94A8");
                    l2.Margin = new Thickness(0, 2, 0, 0);
                    sRow.Children.Add(l2);
                    seCol.Children.Add(sRow);
                }
            }
        }

        // renders a 1000x625 share card and saves PNG to the Desktop
        private void ShareCard()
        {
            try
            {
                long totalSecs = 0; GameEntry topG = null;
                foreach (GameEntry g in gamesRef)
                {
                    totalSecs += g.Seconds;
                    if (topG == null || g.Seconds > topG.Seconds) topG = g;
                }
                HashSet<DateTime> days = new HashSet<DateTime>();
                foreach (SessionEntry e in sessRef) days.Add(e.Start.Date);
                int best = 0, run = 0; DateTime prev = DateTime.MinValue;
                List<DateTime> sd = new List<DateTime>(days); sd.Sort();
                foreach (DateTime d in sd)
                { run = (prev != DateTime.MinValue && (d - prev).Days == 1) ? run + 1 : 1; if (run > best) best = run; prev = d; }

                Border card = new Border();
                card.Width = 1000; card.Height = 625;
                card.CornerRadius = new CornerRadius(0);
                LinearGradientBrush bg = new LinearGradientBrush();
                bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(0.9, 1);
                bg.GradientStops.Add(new GradientStop(Hex("#04070F"), 0.0));
                bg.GradientStops.Add(new GradientStop(Hex("#0A111F"), 0.55));
                bg.GradientStops.Add(new GradientStop(Hex("#101B36"), 1.0));
                card.Background = bg;

                Grid layers = new Grid();
                card.Child = layers;
                Border glow = new Border();
                RadialGradientBrush rg = new RadialGradientBrush();
                rg.Center = new Point(0.85, 1.05); rg.GradientOrigin = new Point(0.85, 1.05);
                rg.RadiusX = 0.9; rg.RadiusY = 0.8;
                rg.GradientStops.Add(new GradientStop(Hex("#55F5C24B"), 0.0));
                rg.GradientStops.Add(new GradientStop(Hex("#00F5C24B"), 1.0));
                glow.Background = rg;
                layers.Children.Add(glow);

                StackPanel col = new StackPanel();
                col.Margin = new Thickness(64, 48, 64, 40);
                layers.Children.Add(col);

                TextBlock hd = new TextBlock();
                hd.Text = "\uD83C\uDFAE  GAMEDOCK";
                hd.FontSize = 30; hd.FontWeight = FontWeights.Bold;
                hd.FontFamily = new FontFamily("Segoe UI Emoji");
                hd.Foreground = BrushH("#F5C24B");
                col.Children.Add(hd);
                TextBlock sub = new TextBlock();
                sub.Text = "MY GAMING STATS  \u00B7  " + DateTime.Today.ToString("d MMM yyyy").ToUpper();
                sub.FontSize = 15; sub.FontWeight = FontWeights.Bold;
                sub.Foreground = BrushH("#5B667A");
                sub.Margin = new Thickness(4, 4, 0, 30);
                col.Children.Add(sub);

                Grid rows = new Grid();
                rows.ColumnDefinitions.Add(new ColumnDefinition());
                rows.ColumnDefinitions.Add(new ColumnDefinition());
                rows.RowDefinitions.Add(new RowDefinition());
                rows.RowDefinitions.Add(new RowDefinition());
                col.Children.Add(rows);
                BigStat(rows, 0, 0, "TOTAL PLAYTIME", FmtHM(totalSecs), "#F5C24B");
                BigStat(rows, 0, 1, "GAMES", gamesRef.Count.ToString(), "#7C8CFF");
                BigStat(rows, 1, 0, "BEST STREAK", (best == 0) ? "--" : best + (best == 1 ? " day" : " days"), "#FB7185");
                BigStat(rows, 1, 1, "TOP GAME", (topG == null || topG.Seconds < 60) ? "--" : topG.Name, "#4ADE80");

                TextBlock ft = new TextBlock();
                ft.Text = "github.com/Lty7o3/gamedock-v1";
                ft.FontSize = 14; ft.FontWeight = FontWeights.SemiBold;
                ft.Foreground = BrushH("#44506A");
                ft.Margin = new Thickness(4, 26, 0, 0);
                col.Children.Add(ft);

                card.Measure(new Size(1000, 625));
                card.Arrange(new Rect(0, 0, 1000, 625));
                card.UpdateLayout();
                System.Windows.Media.Imaging.RenderTargetBitmap rtb =
                    new System.Windows.Media.Imaging.RenderTargetBitmap(1000, 625, 96, 96, PixelFormats.Pbgra32);
                rtb.Render(card);
                System.Windows.Media.Imaging.PngBitmapEncoder enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                string file = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "GameDock-Stats-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".png");
                using (FileStream fs = new FileStream(file, FileMode.Create)) enc.Save(fs);
                MessageBox.Show("Stats card saved to your Desktop:\n\n" + System.IO.Path.GetFileName(file),
                    "GameDock", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Couldn't save the card: " + ex.Message, "GameDock",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void BigStat(Grid rows, int r, int c, string label, string value, string color)
        {
            StackPanel sp = new StackPanel();
            sp.Margin = new Thickness(4, (r == 0) ? 0 : 26, 4, 0);
            Grid.SetRow(sp, r); Grid.SetColumn(sp, c);
            rows.Children.Add(sp);
            TextBlock lb = new TextBlock();
            lb.Text = label; lb.FontSize = 15; lb.FontWeight = FontWeights.Bold;
            lb.Foreground = BrushH("#5B667A");
            sp.Children.Add(lb);
            TextBlock vl = new TextBlock();
            vl.Text = value; vl.FontSize = 52; vl.FontWeight = FontWeights.Bold;
            vl.Foreground = BrushH(color);
            vl.TextTrimming = TextTrimming.CharacterEllipsis;
            vl.Margin = new Thickness(0, 2, 0, 0);
            sp.Children.Add(vl);
        }

        private static string SessionDay(DateTime d)
        {
            if (d.Date == DateTime.Today) return "Today";
            if (d.Date == DateTime.Today.AddDays(-1)) return "Yesterday";
            return d.ToString("ddd d MMM");
        }

        private static string FmtHM(long s)
        {
            long h = s / 3600, m = (s % 3600) / 60;
            if (h > 0) return h + "h " + m + "m";
            if (m > 0) return m + "m";
            return "0m";
        }

        private void Section(StackPanel body, string title)
        {
            TextBlock t = new TextBlock();
            t.Text = title; t.FontSize = 10; t.FontWeight = FontWeights.Bold;
            t.Foreground = BrushH("#4E5A73");
            t.Margin = new Thickness(6, 14, 0, 8);
            body.Children.Add(t);
        }

        // returns "up|+2h 10m vs last week" / "down|-1h vs last week" / "" when no history
        private static string Trend(long now, long prevPeriod, string periodName)
        {
            if (prevPeriod == 0) return "";
            long diff = now - prevPeriod;
            string dir = (diff >= 0) ? "up" : "down";
            return dir + "|" + ((diff >= 0) ? "+" : "-") + FmtHM(Math.Abs(diff)) + " vs " + periodName;
        }

        private void StatCard(Grid cards, int row, int col, string emoji, string label, string value, string color)
        {
            StatCard(cards, row, col, emoji, label, value, color, "");
        }

        private void StatCard(Grid cards, int row, int col, string emoji, string label, string value, string color, string trend)
        {
            Border c = new Border();
            c.CornerRadius = new CornerRadius(16);
            c.Background = BrushH("#B8101827");
            c.BorderThickness = new Thickness(1);
            c.BorderBrush = BrushH("#1E2A44");
            c.Padding = new Thickness(16, 11, 16, 11);
            c.Margin = new Thickness((col == 0) ? 0 : 5, (row == 0) ? 0 : 5, (col == 0) ? 5 : 0, (row == 2) ? 0 : 5);
            Grid.SetRow(c, row); Grid.SetColumn(c, col);
            cards.Children.Add(c);
            StackPanel sp = new StackPanel();
            c.Child = sp;
            StackPanel top = new StackPanel();
            top.Orientation = Orientation.Horizontal;
            TextBlock em = new TextBlock();
            em.Text = emoji; em.FontSize = 11;
            em.FontFamily = new FontFamily("Segoe UI Emoji");
            em.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(em);
            TextBlock lb = new TextBlock();
            lb.Text = "  " + label.ToUpper(); lb.FontSize = 9; lb.FontWeight = FontWeights.Bold;
            lb.Foreground = BrushH("#5B667A"); lb.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(lb);
            sp.Children.Add(top);
            TextBlock val = new TextBlock();
            val.Text = value; val.FontSize = 19; val.FontWeight = FontWeights.Bold;
            val.Foreground = BrushH(color);
            val.Margin = new Thickness(0, 3, 0, 0);
            sp.Children.Add(val);
            if (trend != null && trend.Length > 0)
            {
                int bar = trend.IndexOf('|');
                bool up = trend.Substring(0, bar) == "up";
                TextBlock tr2 = new TextBlock();
                tr2.Text = (up ? "\u25B2 " : "\u25BC ") + trend.Substring(bar + 1);
                tr2.FontSize = 9.5; tr2.FontWeight = FontWeights.Bold;
                tr2.Foreground = BrushH(up ? "#4ADE80" : "#FB7185");
                tr2.Margin = new Thickness(0, 3, 0, 0);
                sp.Children.Add(tr2);
            }
        }
    }

    // width = parent width * fraction (for the most-played bars)
    public class FracConverter : System.Windows.Data.IValueConverter
    {
        public object Convert(object value, Type t, object param, System.Globalization.CultureInfo c)
        {
            double w = (double)value; double f = (double)param;
            double r = w * f; return (r < 2) ? 2.0 : r;
        }
        public object ConvertBack(object value, Type t, object param, System.Globalization.CultureInfo c)
        { return System.Windows.Data.Binding.DoNothing; }
    }

    // ================= MONTHLY WRAPPED (v3.2) =================
    public class WrappedWindow : Window
    {
        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }
        private static string FmtHM(long s)
        {
            long h = s / 3600, mm = (s % 3600) / 60;
            if (h > 0) return h + "h " + mm + "m";
            if (mm > 0) return mm + "m";
            return "0m";
        }

        public WrappedWindow(List<GameEntry> games, List<SessionEntry> sessions, DateTime month)
        {
            Title = "GameDock Wrapped";
            Width = 440; Height = 560;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Topmost = true;

            DateTime mStart = new DateTime(month.Year, month.Month, 1);
            DateTime mEnd = mStart.AddMonths(1);
            DateTime pStart = mStart.AddMonths(-1);

            long secs = 0, prevSecs = 0;
            SessionEntry big = null;
            Dictionary<string, long> perGame = new Dictionary<string, long>();
            HashSet<DateTime> days = new HashSet<DateTime>();
            foreach (SessionEntry e in sessions)
            {
                if (e.Start >= mStart && e.Start < mEnd)
                {
                    secs += e.Seconds;
                    days.Add(e.Start.Date);
                    if (big == null || e.Seconds > big.Seconds) big = e;
                    if (!perGame.ContainsKey(e.Game)) perGame[e.Game] = 0;
                    perGame[e.Game] += e.Seconds;
                }
                else if (e.Start >= pStart && e.Start < mStart) prevSecs += e.Seconds;
            }
            string topGame = "--"; long topSecs = 0;
            foreach (KeyValuePair<string, long> kv in perGame)
                if (kv.Value > topSecs) { topSecs = kv.Value; topGame = kv.Key; }
            int best = 0, run = 0; DateTime prevD = DateTime.MinValue;
            List<DateTime> sd = new List<DateTime>(days); sd.Sort();
            foreach (DateTime d in sd)
            { run = (prevD != DateTime.MinValue && (d - prevD).Days == 1) ? run + 1 : 1; if (run > best) best = run; prevD = d; }

            Border card = new Border();
            card.CornerRadius = new CornerRadius(26);
            card.Margin = new Thickness(14);
            card.BorderThickness = new Thickness(1.5);
            card.BorderBrush = BrushH("#F5C24B");
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(0.9, 1);
            bg.GradientStops.Add(new GradientStop(Hex("#0A0710"), 0.0));
            bg.GradientStops.Add(new GradientStop(Hex("#141126"), 0.55));
            bg.GradientStops.Add(new GradientStop(Hex("#1B1430"), 1.0));
            card.Background = bg;
            DropShadowEffect sh = new DropShadowEffect();
            sh.BlurRadius = 34; sh.ShadowDepth = 0; sh.Opacity = 0.55; sh.Color = Hex("#F5C24B");
            card.Effect = sh;
            Content = card;
            MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };

            Grid layers = new Grid();
            card.Child = layers;
            Border glow = new Border();
            glow.CornerRadius = new CornerRadius(26);
            RadialGradientBrush rg = new RadialGradientBrush();
            rg.Center = new Point(0.5, 1.15); rg.GradientOrigin = new Point(0.5, 1.15);
            rg.RadiusX = 1.0; rg.RadiusY = 0.9;
            rg.GradientStops.Add(new GradientStop(Hex("#40F5C24B"), 0.0));
            rg.GradientStops.Add(new GradientStop(Hex("#00F5C24B"), 1.0));
            glow.Background = rg;
            glow.IsHitTestVisible = false;
            layers.Children.Add(glow);

            StackPanel col = new StackPanel();
            col.Margin = new Thickness(34, 26, 34, 24);
            layers.Children.Add(col);

            Grid top = new Grid();
            col.Children.Add(top);
            TextBlock gift = new TextBlock();
            gift.Text = "\uD83C\uDF81  WRAPPED";
            gift.FontSize = 13; gift.FontWeight = FontWeights.Bold;
            gift.FontFamily = new FontFamily("Segoe UI Emoji");
            gift.Foreground = BrushH("#F5C24B");
            top.Children.Add(gift);
            TextBlock xw = new TextBlock();
            xw.Text = "\u2715"; xw.FontSize = 13; xw.Foreground = BrushH("#8A94A8");
            xw.HorizontalAlignment = HorizontalAlignment.Right;
            xw.Cursor = Cursors.Hand;
            xw.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; Close(); };
            top.Children.Add(xw);

            TextBlock mon = new TextBlock();
            mon.Text = mStart.ToString("MMMM yyyy").ToUpper();
            mon.FontSize = 26; mon.FontWeight = FontWeights.Bold;
            mon.Foreground = BrushH("#EFF3FB");
            mon.Margin = new Thickness(0, 14, 0, 2);
            col.Children.Add(mon);
            TextBlock tag = new TextBlock();
            tag.Text = "your month in gaming";
            tag.FontSize = 12; tag.Foreground = BrushH("#8A94A8");
            tag.Margin = new Thickness(1, 0, 0, 18);
            col.Children.Add(tag);

            WLine(col, "\u23F1", "TOTAL PLAYTIME", FmtHM(secs), "#F5C24B");
            string delta;
            if (prevSecs == 0) delta = (secs > 0) ? "first tracked month!" : "--";
            else
            {
                long diff = secs - prevSecs;
                delta = ((diff >= 0) ? "+" : "-") + FmtHM(Math.Abs(diff)) + " vs last month";
            }
            WLine(col, "\uD83D\uDCC8", "TREND", delta, (secs >= prevSecs) ? "#4ADE80" : "#FB7185");
            WLine(col, "\uD83C\uDFC6", "TOP GAME", topGame + ((topSecs > 0) ? "  (" + FmtHM(topSecs) + ")" : ""), "#7C8CFF");
            WLine(col, "\uD83D\uDCC5", "DAYS PLAYED", days.Count + " of " + DateTime.DaysInMonth(mStart.Year, mStart.Month), "#38BDF8");
            WLine(col, "\uD83D\uDD25", "BEST STREAK", (best == 0) ? "--" : best + (best == 1 ? " day" : " days"), "#FB7185");
            WLine(col, "\uD83D\uDE80", "BIGGEST SESSION",
                (big == null) ? "--" : big.Game + "  \u00B7  " + FmtHM(big.Seconds), "#F472B6");
        }

        private void WLine(StackPanel col, string emoji, string label, string value, string color)
        {
            Border b = new Border();
            b.CornerRadius = new CornerRadius(14);
            b.Background = BrushH("#66101827");
            b.BorderThickness = new Thickness(1);
            b.BorderBrush = BrushH("#2A2440");
            b.Padding = new Thickness(14, 9, 14, 9);
            b.Margin = new Thickness(0, 0, 0, 9);
            col.Children.Add(b);
            Grid g = new Grid();
            b.Child = g;
            StackPanel left = new StackPanel();
            left.Orientation = Orientation.Horizontal;
            g.Children.Add(left);
            TextBlock em = new TextBlock();
            em.Text = emoji; em.FontSize = 13;
            em.FontFamily = new FontFamily("Segoe UI Emoji");
            em.VerticalAlignment = VerticalAlignment.Center;
            left.Children.Add(em);
            TextBlock lb = new TextBlock();
            lb.Text = "  " + label; lb.FontSize = 10; lb.FontWeight = FontWeights.Bold;
            lb.Foreground = BrushH("#8A94A8"); lb.VerticalAlignment = VerticalAlignment.Center;
            left.Children.Add(lb);
            TextBlock vl = new TextBlock();
            vl.Text = value; vl.FontSize = 13.5; vl.FontWeight = FontWeights.Bold;
            vl.Foreground = BrushH(color);
            vl.HorizontalAlignment = HorizontalAlignment.Right;
            vl.VerticalAlignment = VerticalAlignment.Center;
            vl.TextTrimming = TextTrimming.CharacterEllipsis;
            vl.MaxWidth = 210;
            g.Children.Add(vl);
        }
    }

    // ================= SCAN RESULTS PICKER (v3.3) =================
    public class ScanWindow : Window
    {
        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }
        public List<GameEntry> Chosen = new List<GameEntry>();
        private List<CheckBox> boxes = new List<CheckBox>();
        private List<GameEntry> items;

        public ScanWindow(List<GameEntry> found)
        {
            items = found;
            Title = "Games found";
            Width = 430; Height = 520;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;

            Border card = new Border();
            card.CornerRadius = new CornerRadius(20);
            card.Margin = new Thickness(12);
            card.Background = BrushH("#0B1120");
            card.BorderThickness = new Thickness(1);
            card.BorderBrush = BrushH("#2A3752");
            DropShadowEffect sh = new DropShadowEffect();
            sh.BlurRadius = 24; sh.ShadowDepth = 0; sh.Opacity = 0.7; sh.Color = Colors.Black;
            card.Effect = sh;
            Content = card;
            MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };

            Grid root = new Grid();
            root.Margin = new Thickness(22, 18, 22, 18);
            RowDefinition r0 = new RowDefinition(); r0.Height = GridLength.Auto;
            RowDefinition r2 = new RowDefinition(); r2.Height = GridLength.Auto;
            root.RowDefinitions.Add(r0);
            root.RowDefinitions.Add(new RowDefinition());
            root.RowDefinitions.Add(r2);
            card.Child = root;

            StackPanel head = new StackPanel();
            Grid.SetRow(head, 0);
            root.Children.Add(head);
            TextBlock title = new TextBlock();
            title.Text = "\uD83D\uDD0D  FOUND " + found.Count + (found.Count == 1 ? " GAME" : " GAMES");
            title.FontSize = 14; title.FontWeight = FontWeights.Bold;
            title.FontFamily = new FontFamily("Segoe UI Emoji");
            title.Foreground = BrushH("#F5C24B");
            head.Children.Add(title);
            TextBlock hint = new TextBlock();
            hint.Text = "Untick anything that isn't a game, then hit Add.";
            hint.FontSize = 11; hint.Foreground = BrushH("#8A94A8");
            hint.Margin = new Thickness(1, 4, 0, 10);
            head.Children.Add(hint);

            ScrollViewer sc = new ScrollViewer();
            sc.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            Grid.SetRow(sc, 1);
            root.Children.Add(sc);
            StackPanel list = new StackPanel();
            sc.Content = list;
            foreach (GameEntry g in found)
            {
                CheckBox cb = new CheckBox();
                cb.IsChecked = true;
                cb.Margin = new Thickness(2, 5, 0, 5);
                cb.Foreground = BrushH("#DEE6F5");
                StackPanel line = new StackPanel();
                TextBlock nm = new TextBlock();
                nm.Text = g.Name; nm.FontSize = 12.5; nm.FontWeight = FontWeights.SemiBold;
                nm.Foreground = BrushH("#DEE6F5");
                line.Children.Add(nm);
                TextBlock pt = new TextBlock();
                pt.Text = g.Path; pt.FontSize = 9.5;
                pt.Foreground = BrushH("#5B667A");
                pt.TextTrimming = TextTrimming.CharacterEllipsis;
                pt.MaxWidth = 320;
                line.Children.Add(pt);
                cb.Content = line;
                boxes.Add(cb);
                list.Children.Add(cb);
            }

            Grid foot = new Grid();
            foot.Margin = new Thickness(0, 14, 0, 0);
            Grid.SetRow(foot, 2);
            root.Children.Add(foot);
            Border cancel = new Border();
            cancel.CornerRadius = new CornerRadius(16);
            cancel.Padding = new Thickness(18, 8, 18, 8);
            cancel.Background = BrushH("#141D30");
            cancel.BorderThickness = new Thickness(1);
            cancel.BorderBrush = BrushH("#2A3752");
            cancel.Cursor = Cursors.Hand;
            cancel.HorizontalAlignment = HorizontalAlignment.Left;
            TextBlock ct = new TextBlock();
            ct.Text = "Cancel"; ct.FontSize = 12; ct.Foreground = BrushH("#8A94A8");
            cancel.Child = ct;
            cancel.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            { e.Handled = true; DialogResult = false; Close(); };
            foot.Children.Add(cancel);
            Border ok = new Border();
            ok.CornerRadius = new CornerRadius(16);
            ok.Padding = new Thickness(22, 8, 22, 8);
            ok.Background = BrushH("#F5C24B");
            ok.Cursor = Cursors.Hand;
            ok.HorizontalAlignment = HorizontalAlignment.Right;
            TextBlock ot = new TextBlock();
            ot.Text = "Add selected"; ot.FontSize = 12; ot.FontWeight = FontWeights.Bold;
            ot.Foreground = BrushH("#0B0F17");
            ok.Child = ot;
            ok.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
                for (int i = 0; i < boxes.Count; i++)
                    if (boxes[i].IsChecked == true) Chosen.Add(items[i]);
                DialogResult = true; Close();
            };
            foot.Children.Add(ok);
        }
    }

    public class NameDialog : Window
    {
        public string Value;
        private TextBox box;

        public NameDialog(string def) : this(def, "Name this game:") { }

        public NameDialog(string def, string label)
        {
            Title = "GameDock";
            Width = 400; SizeToContent = SizeToContent.Height;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.NoResize;
            Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0B1322"));

            StackPanel p = new StackPanel();
            p.Margin = new Thickness(18);
            Content = p;
            TextBlock lbl = new TextBlock();
            lbl.Text = label;
            lbl.TextWrapping = TextWrapping.Wrap;
            lbl.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#AAB6D6"));
            lbl.FontSize = 13; lbl.Margin = new Thickness(0, 0, 0, 8);
            p.Children.Add(lbl);
            box = new TextBox();
            box.Text = def; box.FontSize = 14; box.Padding = new Thickness(6);
            box.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#131C2E"));
            box.Foreground = Brushes.White;
            box.BorderBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2E3A55"));
            box.CaretBrush = Brushes.White;
            p.Children.Add(box);
            StackPanel btns = new StackPanel();
            btns.Orientation = Orientation.Horizontal;
            btns.HorizontalAlignment = HorizontalAlignment.Right;
            btns.Margin = new Thickness(0, 14, 0, 0);
            p.Children.Add(btns);
            Button ok = new Button();
            ok.Content = "OK"; ok.Width = 80; ok.Height = 28; ok.IsDefault = true;
            ok.Click += delegate { Value = box.Text; DialogResult = true; };
            btns.Children.Add(ok);
            Button cancel = new Button();
            cancel.Content = "Cancel"; cancel.Width = 80; cancel.Height = 28; cancel.IsCancel = true;
            cancel.Margin = new Thickness(8, 0, 0, 0);
            btns.Children.Add(cancel);
            Loaded += delegate { box.SelectAll(); box.Focus(); };
        }
    }
}
'@

$srcFile = Join-Path $installDir 'GameDockApp.cs'
Set-Content -Path $srcFile -Value $csSource -Encoding UTF8
Write-Host "  [OK] App source written." -ForegroundColor Green

# ---------- 2. App icon (gold-ring controller, embedded) ----------
$icoB64 = @'
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAxqb8VAAABAHRSTlP+/v///wD/////////////////////////////////////
ysr/////////////bP8DbP////////85Of//////////TosETov/////////////////////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC7rldgAABNFJREFUeNqllwdX4zgUhWVHcSMuSZzeeydA2hIYel3KMGV3//8/2fck
x5FTYCD3gI8j636678nOiUnY1919TZKkkKC9hYQxmFK7v1u6CDsehMOH6A4C9rYAkHHITAvAQXju2TcHEAEeQarNOYEw/6EkfRYgSYeMAIBbwS8S0HkC2uJH
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAx1BXJQAAAQB0Uk5T/v7//gD/////////////////////////////////////////
/////////////////////////////////wQvL///aGj/ygPK/7CwlZX/////TEz///////8R/////////////wL/Gf//xv//AAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL02fBYAAB9eSURBVHja5Z35Q9pKv8YnhhChIIJtFUSK+AJ6UQ4urUutS6vHul672L09
67vce///3++smSWTZBKgtjLnPV08GOb5zPNdZhJ8Qcp8PHuGf/u4/+Li7OTEwsM2HPfobwbDjjfINP7n5Ozixf5HcZ5mA5i+8Fd86f0XZ0x5PABMvwmEJADo
7ydnL/afedMdIAB0vY+vL6h4PuxhAEhAgOonEC5efzRHYOqAj6/PLN2IC+CebRoEJhiQD30A0Dh7/XGgDti/sKzB6I/U7hEw84HFQsA3tYv9gQEIWPwEAAzT
4D1zBzDltmZyZ6/7BwAD6fWJZYUBsGJlgHv37g2wElhCFtRN7+R1ZC4IBQDz6X7Q6tvxHTB4AHYEAOiCfSwjqQMCY9+yhwrAHhiAyFwAwtz/Isz7QwJgxyoD
BgAs60VYHIQ4YP/MMgBgWcMCYA8KAIqDX+MDCFl+7w15JjItA0b+T5IDQmeLTBALwLPUxwvLAIA16DaAmaCfTlCfCT4G5EKg179/YkUBsJPkAAPxdqIQiBwn
+3oCQKv/dfQFh+aAZAAMMLzWEgA6/S8M9McFoFf76NEj9EvffYCRD17oCPgB/G2iP+5umC6s6WbAHgoASODvaABG659kL3DPXwUfIQc8In9Keh4SB4DOA6Av
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
'@
$icoPath = Join-Path $installDir 'gamedock.ico'
[System.IO.File]::WriteAllBytes($icoPath, [Convert]::FromBase64String(($icoB64 -replace '\s','')))
Write-Host "  [OK] App icon written." -ForegroundColor Green

# ---------- 3. Compile ----------
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
if (-not (Test-Path "$fw\csc.exe")) { $fw = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319" }
if (-not (Test-Path "$fw\csc.exe")) { Write-Host "  [X] C# compiler not found." -ForegroundColor Red; return }
$wpf = Join-Path $fw 'WPF'
$exePath = Join-Path $installDir 'GameDock.exe'
$refs = @(
    "/r:$wpf\PresentationFramework.dll",
    "/r:$wpf\PresentationCore.dll",
    "/r:$wpf\WindowsBase.dll",
    "/r:$fw\System.Xaml.dll",
    "/r:System.dll",
    "/r:System.Core.dll",
    "/r:System.Drawing.dll",
    "/r:System.Windows.Forms.dll"
)
Remove-Item $exePath -Force -ErrorAction SilentlyContinue
$out = & "$fw\csc.exe" /nologo /target:winexe "/win32icon:$icoPath" "/out:$exePath" @refs "$srcFile" 2>&1
if (-not (Test-Path $exePath)) {
    Write-Host "  [X] Compile failed:" -ForegroundColor Red
    $out | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    return
}
Write-Host "  [OK] Compiled GameDock v2." -ForegroundColor Green

# ---------- 4. Desktop copy ----------
$desktopExe = Join-Path $desktop 'GameDock.exe'
Remove-Item -LiteralPath $desktopExe -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $exePath -Destination $desktopExe -Force
Write-Host "  [OK] Copied to Desktop." -ForegroundColor Green

# ---------- 5. Launch ----------
Start-Process -FilePath $desktopExe

Write-Host ""
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host "   GAMEDOCK V3.4 INSTALLED!" -ForegroundColor Green
Write-Host "   - Playtime shows under each game (gold)" -ForegroundColor Green
Write-Host "   - FPS button (top right) toggles the overlay" -ForegroundColor Green
Write-Host "   - Search bar to filter your library" -ForegroundColor Green
Write-Host "   - NEW: idle guard + session goal + Ctrl+Shift+F" -ForegroundColor Green
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host ""
