# ============================================================
#   GAMEDOCK  -  one-paste installer  (share this file!)
# ============================================================
#   WHAT IT IS : A sleek game launcher app for Windows 11.
#                Wide bubble buttons, real game icons, dark UI.
#   HOW TO USE : 1. Open PowerShell (Win key -> type powershell)
#                2. Paste this ENTIRE script, press Enter
#                   (press Enter once more if it waits)
#                3. Done - GameDock.exe appears on your Desktop
#                   and opens by itself.
#   IT BUILDS a real native Windows app (C#/WPF) using the
#   compiler built into Windows - no downloads, no PowerShell
#   needed ever again after this one paste.
#   Your games are saved in %APPDATA%\GameDock so they persist.
# ============================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$installDir = Join-Path $env:LOCALAPPDATA 'GameDock'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$desktop = [Environment]::GetFolderPath('Desktop')

# ---------- 0. Close any running copy, clean old junk ----------
Get-Process GameDock -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
foreach ($f in 'GameDock.vbs','GameDock-launch.cmd','launcher.cs') {
    Remove-Item -LiteralPath (Join-Path $installDir $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $desktop 'GameDock.lnk') -Force -ErrorAction SilentlyContinue

# ---------- 1. The full app source (C# / WPF, all fixes included) ----------
$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace GameDock
{
    public class GameEntry
    {
        public string Name;
        public string Path;
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

    public class MainWindow : Window
    {
        private List<GameEntry> games = new List<GameEntry>();
        private StackPanel listPanel;
        private TextBlock subtitle;

        private static string DataDir
        {
            get { return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GameDock"); }
        }
        private static string DataFile { get { return System.IO.Path.Combine(DataDir, "games.txt"); } }

        private static readonly string[] Accents = new string[] {
            "#7C8CFF", "#4ADE80", "#F472B6", "#FBBF24", "#38BDF8", "#FB7185", "#A78BFA", "#34D399" };

        private static Color Hex(string s) { return (Color)ColorConverter.ConvertFromString(s); }
        private static SolidColorBrush BrushH(string s) { return new SolidColorBrush(Hex(s)); }
        private static RowDefinition RowAuto() { RowDefinition r = new RowDefinition(); r.Height = GridLength.Auto; return r; }
        private static ColumnDefinition ColAuto() { ColumnDefinition c = new ColumnDefinition(); c.Width = GridLength.Auto; return c; }

        public MainWindow()
        {
            Title = "GameDock";
            Width = 420; Height = 560;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;

            Border card = new Border();
            card.CornerRadius = new CornerRadius(22);
            card.Margin = new Thickness(12);
            LinearGradientBrush bg = new LinearGradientBrush();
            bg.StartPoint = new Point(0, 0);
            bg.EndPoint = new Point(1, 1);
            bg.GradientStops.Add(new GradientStop(Hex("#0B0F17"), 0.0));
            bg.GradientStops.Add(new GradientStop(Hex("#121A2B"), 1.0));
            card.Background = bg;
            DropShadowEffect shadow = new DropShadowEffect();
            shadow.BlurRadius = 26; shadow.ShadowDepth = 0; shadow.Opacity = 0.65; shadow.Color = Colors.Black;
            card.Effect = shadow;
            Content = card;

            Grid root = new Grid();
            root.Margin = new Thickness(22, 18, 22, 20);
            root.RowDefinitions.Add(RowAuto());
            root.RowDefinitions.Add(RowAuto());
            root.RowDefinitions.Add(new RowDefinition());
            root.RowDefinitions.Add(RowAuto());
            card.Child = root;

            // ---- Title bar ----
            Grid titleBar = new Grid();
            titleBar.Background = Brushes.Transparent;
            Grid.SetRow(titleBar, 0);
            root.Children.Add(titleBar);
            titleBar.MouseLeftButtonDown += delegate { try { DragMove(); } catch { } };

            StackPanel titleLeft = new StackPanel();
            titleLeft.Orientation = Orientation.Horizontal;
            titleLeft.VerticalAlignment = VerticalAlignment.Center;
            TextBlock pad = new TextBlock();
            pad.Text = "\uD83C\uDFAE"; pad.FontSize = 18; pad.VerticalAlignment = VerticalAlignment.Center;
            pad.FontFamily = new FontFamily("Segoe UI Emoji");
            TextBlock name = new TextBlock();
            name.Text = "  GAMEDOCK"; name.FontSize = 15; name.FontWeight = FontWeights.Bold;
            name.Foreground = BrushH("#E8EDF7"); name.VerticalAlignment = VerticalAlignment.Center;
            titleLeft.Children.Add(pad); titleLeft.Children.Add(name);
            titleBar.Children.Add(titleLeft);

            StackPanel titleRight = new StackPanel();
            titleRight.Orientation = Orientation.Horizontal;
            titleRight.HorizontalAlignment = HorizontalAlignment.Right;
            titleBar.Children.Add(titleRight);

            Border btnMin = MakeChromeButton("\u2013", "#22293A");
            btnMin.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; WindowState = WindowState.Minimized; };
            titleRight.Children.Add(btnMin);

            Border btnClose = MakeChromeButton("\u2715", "#E81123");
            btnClose.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { e.Handled = true; Close(); };
            titleRight.Children.Add(btnClose);

            // ---- Subtitle ----
            subtitle = new TextBlock();
            subtitle.Text = "YOUR LIBRARY";
            subtitle.FontSize = 10; subtitle.FontWeight = FontWeights.SemiBold;
            subtitle.Foreground = BrushH("#4E5A73");
            subtitle.Margin = new Thickness(4, 10, 0, 10);
            Grid.SetRow(subtitle, 1);
            root.Children.Add(subtitle);

            // ---- Scrollable bubble list ----
            ScrollViewer scroll = new ScrollViewer();
            scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            Grid.SetRow(scroll, 2);
            root.Children.Add(scroll);
            listPanel = new StackPanel();
            listPanel.Margin = new Thickness(0, 0, 4, 0);
            scroll.Content = listPanel;

            // ---- Add-game bubble ----
            Border addBtn = new Border();
            addBtn.CornerRadius = new CornerRadius(26);
            addBtn.Height = 52;
            addBtn.Margin = new Thickness(0, 14, 4, 0);
            addBtn.BorderThickness = new Thickness(1.5);
            addBtn.BorderBrush = BrushH("#2E3A55");
            addBtn.Background = BrushH("#141B2B");
            addBtn.Cursor = Cursors.Hand;
            StackPanel addRow = new StackPanel();
            addRow.Orientation = Orientation.Horizontal;
            addRow.HorizontalAlignment = HorizontalAlignment.Center;
            addRow.VerticalAlignment = VerticalAlignment.Center;
            TextBlock plus = new TextBlock();
            plus.Text = "+"; plus.FontSize = 20; plus.FontWeight = FontWeights.Bold;
            plus.Foreground = BrushH("#7C8CFF"); plus.Margin = new Thickness(0, -3, 8, 0);
            TextBlock addTxt = new TextBlock();
            addTxt.Text = "Add a game"; addTxt.FontSize = 14; addTxt.FontWeight = FontWeights.SemiBold;
            addTxt.Foreground = BrushH("#AAB6D6");
            addRow.Children.Add(plus); addRow.Children.Add(addTxt);
            addBtn.Child = addRow;
            addBtn.MouseEnter += delegate { addBtn.Background = BrushH("#1B2438"); addBtn.BorderBrush = BrushH("#7C8CFF"); };
            addBtn.MouseLeave += delegate { addBtn.Background = BrushH("#141B2B"); addBtn.BorderBrush = BrushH("#2E3A55"); };
            addBtn.MouseLeftButtonUp += delegate { AddGame(); };
            Grid.SetRow(addBtn, 3);
            root.Children.Add(addBtn);

            LoadGames();
            RefreshList();
        }

        private Border MakeChromeButton(string glyph, string hoverColor)
        {
            Border b = new Border();
            b.Width = 30; b.Height = 30;
            b.CornerRadius = new CornerRadius(8);
            b.Background = Brushes.Transparent;
            b.Cursor = Cursors.Hand;
            TextBlock t = new TextBlock();
            t.Text = glyph; t.FontSize = 12;
            t.Foreground = BrushH("#8A94A8");
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            b.Child = t;
            b.MouseEnter += delegate { b.Background = BrushH(hoverColor); t.Foreground = Brushes.White; };
            b.MouseLeave += delegate { b.Background = Brushes.Transparent; t.Foreground = BrushH("#8A94A8"); };
            return b;
        }

        // ---------- storage ----------
        private void LoadGames()
        {
            games.Clear();
            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
                if (File.Exists(DataFile))
                {
                    foreach (string line in File.ReadAllLines(DataFile))
                    {
                        int i = line.IndexOf('\t');
                        if (i <= 0) continue;
                        string n = line.Substring(0, i).Trim();
                        string p = line.Substring(i + 1).Trim();
                        if (n.Length == 0 || p.Length == 0) continue;
                        GameEntry g = new GameEntry(); g.Name = n; g.Path = p;
                        games.Add(g);
                    }
                }
            }
            catch { }
        }

        private void SaveGames()
        {
            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
                List<string> lines = new List<string>();
                foreach (GameEntry g in games) lines.Add(g.Name + "\t" + g.Path);
                File.WriteAllLines(DataFile, lines.ToArray());
            }
            catch { }
        }

        // ---------- UI list ----------
        private void RefreshList()
        {
            listPanel.Children.Clear();
            if (games.Count == 0)
            {
                TextBlock empty = new TextBlock();
                empty.Text = "No games yet - hit  +  below to add your first one";
                empty.FontSize = 12.5;
                empty.Foreground = BrushH("#4E5A73");
                empty.HorizontalAlignment = HorizontalAlignment.Center;
                empty.Margin = new Thickness(0, 40, 0, 0);
                listPanel.Children.Add(empty);
            }
            else
            {
                int i = 0;
                foreach (GameEntry g in games)
                {
                    listPanel.Children.Add(MakeBubble(g, i));
                    i++;
                }
            }
            subtitle.Text = "YOUR LIBRARY  -  " + games.Count + (games.Count == 1 ? " GAME" : " GAMES");
        }

        private Border MakeBubble(GameEntry game, int index)
        {
            string accent = Accents[index % Accents.Length];

            Border bubble = new Border();
            bubble.CornerRadius = new CornerRadius(28);
            bubble.Height = 56;
            bubble.Margin = new Thickness(0, 0, 0, 10);
            bubble.Background = BrushH("#1A2233");
            bubble.Cursor = Cursors.Hand;

            Grid grid = new Grid();
            grid.Margin = new Thickness(8, 0, 10, 0);
            grid.ColumnDefinitions.Add(ColAuto());
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(ColAuto());
            grid.ColumnDefinitions.Add(ColAuto());
            bubble.Child = grid;

            // round icon chip
            Border chip = new Border();
            chip.Width = 40; chip.Height = 40;
            chip.CornerRadius = new CornerRadius(20);
            chip.VerticalAlignment = VerticalAlignment.Center;
            chip.Background = BrushH(accent);
            ImageSource ico = GetIcon(game.Path);
            if (ico != null)
            {
                Image img = new Image();
                img.Source = ico; img.Width = 24; img.Height = 24;
                img.HorizontalAlignment = HorizontalAlignment.Center;
                img.VerticalAlignment = VerticalAlignment.Center;
                chip.Child = img;
            }
            else
            {
                TextBlock letter = new TextBlock();
                letter.Text = game.Name.Substring(0, 1).ToUpper();
                letter.FontSize = 17; letter.FontWeight = FontWeights.Bold;
                letter.Foreground = Brushes.White;
                letter.HorizontalAlignment = HorizontalAlignment.Center;
                letter.VerticalAlignment = VerticalAlignment.Center;
                chip.Child = letter;
            }
            Grid.SetColumn(chip, 0);
            grid.Children.Add(chip);

            // name
            TextBlock nameTxt = new TextBlock();
            nameTxt.Text = game.Name;
            nameTxt.FontSize = 14; nameTxt.FontWeight = FontWeights.SemiBold;
            nameTxt.Foreground = BrushH("#DEE6F5");
            nameTxt.VerticalAlignment = VerticalAlignment.Center;
            nameTxt.Margin = new Thickness(14, 0, 8, 0);
            nameTxt.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(nameTxt, 1);
            grid.Children.Add(nameTxt);

            // play pill
            Border play = new Border();
            play.CornerRadius = new CornerRadius(16);
            play.Padding = new Thickness(16, 6, 16, 6);
            play.VerticalAlignment = VerticalAlignment.Center;
            play.Background = BrushH(accent);
            play.Opacity = 0.92;
            TextBlock playTxt = new TextBlock();
            playTxt.Text = "\u25B6"; playTxt.FontSize = 11;
            playTxt.Foreground = BrushH("#0B0F17");
            play.Child = playTxt;
            Grid.SetColumn(play, 2);
            grid.Children.Add(play);

            // remove X
            TextBlock rem = new TextBlock();
            rem.Text = "\u2715"; rem.FontSize = 11;
            rem.Foreground = BrushH("#55617A");
            rem.VerticalAlignment = VerticalAlignment.Center;
            rem.Margin = new Thickness(12, 0, 4, 0);
            rem.Cursor = Cursors.Hand;
            rem.ToolTip = "Remove from dock";
            Grid.SetColumn(rem, 3);
            grid.Children.Add(rem);

            // hover
            bubble.MouseEnter += delegate { bubble.Background = BrushH("#232E47"); };
            bubble.MouseLeave += delegate { bubble.Background = BrushH("#1A2233"); };

            // launch
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

            // remove (mouse-down so the bubble's launch never fires)
            rem.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                e.Handled = true;
                games.Remove(captured);
                SaveGames();
                RefreshList();
            };

            return bubble;
        }

        private ImageSource GetIcon(string path)
        {
            try
            {
                string target = ResolveLnk(path);
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
            if (!path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) return path;
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

        // ---------- add game ----------
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
                g.Name = chosen.Trim();
                g.Path = dlg.FileName;
                games.Add(g);
                SaveGames();
                RefreshList();
            }
        }
    }

    public class NameDialog : Window
    {
        public string Value;
        private TextBox box;

        public NameDialog(string def)
        {
            Title = "Name this game";
            Width = 380; Height = 170;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.NoResize;
            Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#121A2B"));

            StackPanel p = new StackPanel();
            p.Margin = new Thickness(18);
            Content = p;

            TextBlock lbl = new TextBlock();
            lbl.Text = "Name this game:";
            lbl.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#AAB6D6"));
            lbl.FontSize = 13;
            lbl.Margin = new Thickness(0, 0, 0, 8);
            p.Children.Add(lbl);

            box = new TextBox();
            box.Text = def;
            box.FontSize = 14;
            box.Padding = new Thickness(6);
            box.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#1A2233"));
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

# ---------- 2. Draw the app icon (purple bubble + play arrow) ----------
function New-IconPngBytes([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $rect = New-Object System.Drawing.Rectangle(0, 0, ($size-1), ($size-1))
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.ColorTranslator]::FromHtml('#8B9CFF'),
        [System.Drawing.ColorTranslator]::FromHtml('#4F46E5'),
        45)
    $g.FillEllipse($grad, 0, 0, ($size-1), ($size-1))
    $p1 = New-Object System.Drawing.PointF(($size*0.40), ($size*0.28))
    $p2 = New-Object System.Drawing.PointF(($size*0.40), ($size*0.72))
    $p3 = New-Object System.Drawing.PointF(($size*0.76), ($size*0.50))
    $g.FillPolygon([System.Drawing.Brushes]::White, @($p1, $p2, $p3))
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return ,$bytes
}

$sizes = @(16, 24, 32, 48, 64, 256)
$pngs = @()
foreach ($s in $sizes) { $pngs += ,(New-IconPngBytes $s) }

$icoPath = Join-Path $installDir 'gamedock.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $b = $pngs[$i]
    $wb = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$wb); $bw.Write([byte]$wb)
    $bw.Write([byte]0);  $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$b.Length); $bw.Write([uint32]$offset)
    $offset += $b.Length
}
foreach ($b in $pngs) { $bw.Write($b) }
$bw.Close(); $fs.Close()
Write-Host "  [OK] App icon created." -ForegroundColor Green

# ---------- 3. Compile a real Windows exe (icon baked in) ----------
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
if (-not (Test-Path "$fw\csc.exe")) { $fw = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319" }
if (-not (Test-Path "$fw\csc.exe")) {
    Write-Host "  [X] C# compiler not found on this PC." -ForegroundColor Red
    return
}
$wpf = Join-Path $fw 'WPF'
$exePath = Join-Path $installDir 'GameDock.exe'

$refs = @(
    "/r:$wpf\PresentationFramework.dll",
    "/r:$wpf\PresentationCore.dll",
    "/r:$wpf\WindowsBase.dll",
    "/r:$fw\System.Xaml.dll",
    "/r:System.dll",
    "/r:System.Core.dll",
    "/r:System.Drawing.dll"
)
Remove-Item $exePath -Force -ErrorAction SilentlyContinue
$out = & "$fw\csc.exe" /nologo /target:winexe "/win32icon:$icoPath" "/out:$exePath" @refs "$srcFile" 2>&1
if (-not (Test-Path $exePath)) {
    Write-Host "  [X] Compile failed:" -ForegroundColor Red
    $out | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    return
}
Write-Host "  [OK] Compiled native app: $exePath" -ForegroundColor Green

# ---------- 4. Copy onto the Desktop (plain file copy = works with any language) ----------
$desktopExe = Join-Path $desktop 'GameDock.exe'
Remove-Item -LiteralPath $desktopExe -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $exePath -Destination $desktopExe -Force
Write-Host "  [OK] Copied to Desktop." -ForegroundColor Green

# ---------- 5. Launch ----------
Start-Process -FilePath $desktopExe

Write-Host ""
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host "   GAMEDOCK INSTALLED!" -ForegroundColor Green
Write-Host "   Double-click GameDock.exe on your Desktop any time." -ForegroundColor Green
Write-Host "   Add games with the + button - they're saved forever." -ForegroundColor Green
Write-Host "  ====================================================" -ForegroundColor DarkGray
Write-Host ""
