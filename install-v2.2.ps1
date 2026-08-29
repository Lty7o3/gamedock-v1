# ============================================================
#   GAMEDOCK V2  -  one-paste installer
# ============================================================
#   V2.2 - TRAY UPDATE
#    - Pressing X now hides GameDock to the system tray:
#      playtime KEEPS COUNTING in the background
#      (double-click tray icon to open, right-click > Exit)
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
    }

    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            Application app = new Application();
            app.Run(new MainWindow());
        }
    }

    // ================= FPS / PERFORMANCE OVERLAY =================
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

        private int frames;
        private TextBlock txtFps, txtCpu, txtRam;
        private DispatcherTimer timer;
        private PerformanceCounter cpu;

        public OverlayWindow()
        {
            Width = 250; Height = 44;
            WindowStyle = WindowStyle.None; AllowsTransparency = true;
            Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            Left = SystemParameters.WorkArea.Width - Width - 24; Top = 24;

            Border pill = new Border();
            pill.CornerRadius = new CornerRadius(22);
            pill.BorderThickness = new Thickness(1);
            pill.BorderBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#3D3320"));
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0); bg.EndPoint = new Point(1, 1);
            bg.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#0A0F1C"), 0.0));
            bg.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#131C30"), 1.0));
            pill.Background = bg;
            DropShadowEffect sh = new DropShadowEffect();
            sh.BlurRadius = 16; sh.ShadowDepth = 0; sh.Opacity = 0.6; sh.Color = Colors.Black;
            pill.Effect = sh;
            Content = pill;

            StackPanel row = new StackPanel();
            row.Orientation = Orientation.Horizontal;
            row.HorizontalAlignment = HorizontalAlignment.Center;
            row.VerticalAlignment = VerticalAlignment.Center;
            pill.Child = row;

            txtFps = Metric(row, "FPS", "#F5C24B");
            Sep(row); txtCpu = Metric(row, "CPU", "#7C8CFF");
            Sep(row); txtRam = Metric(row, "RAM", "#4ADE80");

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

            timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromSeconds(1);
            timer.Tick += delegate
            {
                txtFps.Text = frames.ToString(); frames = 0;
                if (cpu != null) { try { txtCpu.Text = ((int)cpu.NextValue()).ToString() + "%"; } catch { } }
                MEMORYSTATUSEX m = new MEMORYSTATUSEX();
                m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                if (GlobalMemoryStatusEx(ref m))
                {
                    double used = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
                    txtRam.Text = used.ToString("0.0") + "G";
                }
            };
            timer.Start();
            Closed += delegate { timer.Stop(); CompositionTarget.Rendering -= delegate { }; };
        }

        private TextBlock Metric(StackPanel row, string label, string color)
        {
            TextBlock lbl = new TextBlock();
            lbl.Text = label; lbl.FontSize = 9; lbl.FontWeight = FontWeights.Bold;
            lbl.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#5B667A"));
            lbl.VerticalAlignment = VerticalAlignment.Center;
            lbl.Margin = new Thickness(12, 0, 5, 0);
            row.Children.Add(lbl);
            TextBlock val = new TextBlock();
            val.Text = "--"; val.FontSize = 15; val.FontWeight = FontWeights.Bold;
            val.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
            val.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(val);
            return val;
        }
        private void Sep(StackPanel row)
        {
            Border b = new Border();
            b.Width = 1; b.Height = 16;
            b.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#232C40"));
            b.Margin = new Thickness(10, 0, 0, 0);
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

        private static string DataDir
        { get { return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GameDock"); } }
        private static string DataFile { get { return System.IO.Path.Combine(DataDir, "games2.txt"); } }
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
            v2.Text = " V2.2"; v2.FontSize = 10; v2.FontWeight = FontWeights.Bold;
            v2.Foreground = BrushH("#F5C24B"); v2.VerticalAlignment = VerticalAlignment.Center;
            v2.Margin = new Thickness(2, 0, 0, 6);
            titleLeft.Children.Add(v2);
            titleBar.Children.Add(titleLeft);

            StackPanel titleRight = new StackPanel();
            titleRight.Orientation = Orientation.Horizontal;
            titleRight.HorizontalAlignment = HorizontalAlignment.Right;
            titleBar.Children.Add(titleRight);

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
            totalTime = new TextBlock();
            totalTime.FontSize = 10; totalTime.FontWeight = FontWeights.SemiBold;
            totalTime.Foreground = BrushH("#F5C24B");
            totalTime.HorizontalAlignment = HorizontalAlignment.Right;
            subRow.Children.Add(totalTime);

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
            Grid.SetRow(addBtn, 4);
            root.Children.Add(addBtn);

            LoadGames();
            RefreshList();

            // ---------- Playtime tracker: ticks every 5s ----------
            trackTimer = new DispatcherTimer();
            trackTimer.Interval = TimeSpan.FromSeconds(5);
            trackTimer.Tick += delegate { TrackTick(); };
            trackTimer.Start();

            // ---------- system tray ----------
            SetupTray();
            Closing += delegate(object s, System.ComponentModel.CancelEventArgs e)
            {
                if (!reallyExit) { e.Cancel = true; HideToTray(); return; }
            };
            Closed += delegate
            {
                SaveGames();
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
            WinForms.ToolStripMenuItem miExit = new WinForms.ToolStripMenuItem("Exit (stop tracking)");
            miExit.Click += delegate { reallyExit = true; Close(); };
            menu.Items.Add(miExit);
            tray.ContextMenuStrip = menu;
        }

        private void HideToTray()
        {
            Hide();
            if (tray != null)
            {
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
            foreach (GameEntry g in games)
            {
                try
                {
                    foreach (string cand in TrackCandidates(g))
                    {
                        if (Process.GetProcessesByName(cand).Length > 0)
                        {
                            g.Seconds += 5; any = true; break;
                        }
                    }
                }
                catch { }
            }
            saveCountdown--;
            if (saveCountdown <= 0) { saveCountdown = 12; if (any) { SaveGames(); RefreshList(); } }
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
                    lines.Add(g.Name + "\t" + g.Path + "\t" + g.Seconds + "\t" + (g.TrackName == null ? "" : g.TrackName));
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
            timeTxt.Text = "\u23F1 " + FormatTime(game.Seconds);
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

            TextBlock rem = new TextBlock();
            rem.Text = "\u2715"; rem.FontSize = 11;
            rem.Foreground = BrushH("#55617A");
            rem.VerticalAlignment = VerticalAlignment.Center;
            rem.Margin = new Thickness(13, 0, 3, 0);
            rem.Cursor = Cursors.Hand; rem.ToolTip = "Remove from dock";
            Grid.SetColumn(rem, 4);
            grid.Children.Add(rem);

            bubble.MouseEnter += delegate { bubble.Background = BrushH("#E01B2942"); bubble.BorderBrush = BrushH(accent); };
            bubble.MouseLeave += delegate { bubble.Background = BrushH("#CC131C2E"); bubble.BorderBrush = BrushH("#1B2740"); };

            GameEntry captured = game;
            bubble.MouseLeftButtonUp += delegate
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(captured.Path);
                    psi.UseShellExecute = true;
                    Process.Start(psi);
                }
                catch
                {
                    MessageBox.Show("Couldn't launch:\n" + captured.Path, "GameDock",
                        MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            };
            rem.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
                games.Remove(captured);
                SaveGames(); RefreshList();
            };

            // pencil: set the tracked process for playtime
            TextBlock edit = new TextBlock();
            edit.Text = "\u270E"; edit.FontSize = 13;
            edit.Foreground = BrushH(game.TrackName != null ? "#F5C24B" : "#55617A");
            edit.VerticalAlignment = VerticalAlignment.Center;
            edit.Margin = new Thickness(12, 0, 0, 0);
            edit.Cursor = Cursors.Hand;
            edit.ToolTip = "Playtime not counting? Set the game's real process name here (Task Manager > Details)";
            Grid.SetColumn(edit, 3);
            grid.Children.Add(edit);
            edit.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
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
Write-Host "   GAMEDOCK V2.2 INSTALLED!" -ForegroundColor Green
Write-Host "   - Playtime shows under each game (gold)" -ForegroundColor Green
Write-Host "   - FPS button (top right) toggles the overlay" -ForegroundColor Green
Write-Host "   - Search bar to filter your library" -ForegroundColor Green
Write-Host "   - X now hides to tray - playtime keeps counting" -ForegroundColor Green
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host ""
