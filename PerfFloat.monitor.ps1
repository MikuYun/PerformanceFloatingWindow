# PerfFloat Monitor v6
# WinForms custom-rendered floating performance dashboard.
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Management
[System.Windows.Forms.Application]::EnableVisualStyles()

$perfFloatWin32Src = @'
using System;
using System.Runtime.InteropServices;
public static class PerfFloatWin32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20;
}
'@

$hotKeyFormSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class HotKeyForm : Form {
    public delegate void HotKeyCallback(int id);
    public delegate void PassThroughCallback();
    public event HotKeyCallback HotKeyPressed;
    public event PassThroughCallback PassThroughButtonClicked;
    private const int WM_HOTKEY = 0x0312;
    private const int WH_MOUSE_LL = 14;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MousePoint { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct LowLevelMouseData { public MousePoint Point; public uint MouseData; public uint Flags; public uint Time; public IntPtr ExtraInfo; }
    private delegate IntPtr LowLevelMouseProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool GetWindowRect(IntPtr hWnd, out WindowRect rect);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    private LowLevelMouseProc mouseProc;
    private IntPtr mouseHook = IntPtr.Zero;
    public bool PassThrough { get; set; }
    public int PassThroughLeft { get; set; }
    public int PassThroughTop { get; set; }
    public int PassThroughRight { get; set; }
    public int PassThroughBottom { get; set; }
    public bool EnablePassThroughButtonHook() {
        if (mouseHook != IntPtr.Zero) return true;
        mouseProc = MouseHookCallback;
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
        return mouseHook != IntPtr.Zero;
    }
    public void DisablePassThroughButtonHook() {
        if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
        mouseHook = IntPtr.Zero;
        mouseProc = null;
    }
    private IntPtr MouseHookCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && PassThrough) {
            int message = wParam.ToInt32();
            if (message == WM_LBUTTONDOWN || message == WM_LBUTTONUP) {
                LowLevelMouseData data = (LowLevelMouseData)Marshal.PtrToStructure(lParam, typeof(LowLevelMouseData));
                WindowRect rect;
                if (GetWindowRect(this.Handle, out rect)) {
                    int x = data.Point.X - rect.Left;
                    int y = data.Point.Y - rect.Top;
                    if (x >= PassThroughLeft && x < PassThroughRight && y >= PassThroughTop && y < PassThroughBottom) {
                        if (message == WM_LBUTTONUP) {
                            PassThroughCallback callback = PassThroughButtonClicked;
                            if (callback != null) callback();
                        }
                        return new IntPtr(1);
                    }
                }
            }
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            HotKeyCallback c = HotKeyPressed;
            if (c != null) c(m.WParam.ToInt32());
        }
        base.WndProc(ref m);
    }
    protected override void Dispose(bool disposing) {
        DisablePassThroughButtonHook();
        base.Dispose(disposing);
    }
}
'@

try { Add-Type -TypeDefinition $perfFloatWin32Src -ErrorAction Stop } catch { }
try { Add-Type -TypeDefinition $hotKeyFormSrc -ReferencedAssemblies @([System.Windows.Forms.Form].Assembly.Location) -ErrorAction Stop } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'PerfFloatMonitor.config.ini'
$statePath = Join-Path $scriptDir 'PerfFloatMonitor.state.ini'
$mutexName = 'Local\PerfFloatMonitor_v6'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

function Read-KeyValueFile([string]$path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    foreach ($raw in [System.IO.File]::ReadAllLines($path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { continue }
        $key = $line.Substring(0, $index).Trim().ToLowerInvariant()
        $value = $line.Substring($index + 1).Trim()
        $result[$key] = $value
    }
    return $result
}

function Get-Setting($map, [string[]]$names, $defaultValue) {
    foreach ($name in $names) {
        $key = $name.ToLowerInvariant()
        if ($map.ContainsKey($key) -and $map[$key] -ne '') { return $map[$key] }
    }
    return $defaultValue
}

function Get-Int($value, [int]$defaultValue, [int]$minimum, [int]$maximum) {
    $parsed = 0
    if (-not [int]::TryParse([string]$value, [ref]$parsed)) { $parsed = $defaultValue }
    return [Math]::Min($maximum, [Math]::Max($minimum, $parsed))
}

function Get-Bool($value, [bool]$defaultValue) {
    if ($null -eq $value) { return $defaultValue }
    switch ([string]$value.ToLowerInvariant()) {
        { $_ -in @('1','true','yes','on') } { return $true }
        { $_ -in @('0','false','no','off') } { return $false }
        default { return $defaultValue }
    }
}

function Parse-Color([string]$value, [System.Drawing.Color]$fallback) {
    try {
        if ($value -match '^#[0-9a-fA-F]{6}$') { return [System.Drawing.ColorTranslator]::FromHtml($value) }
    } catch {}
    return $fallback
}

$configFile = Read-KeyValueFile $configPath
$stateFile = Read-KeyValueFile $statePath

$themeName = [string](Get-Setting $configFile @('theme') 'frost')
$themeName = $themeName.ToLowerInvariant()
$themes = [ordered]@{
    frost = @{ bg='#EAF1F8'; card='#F8FBFF'; card2='#EDF4FA'; text='#182437'; muted='#66758A'; accent='#5278E5'; cyan='#189DB5'; good='#259B72'; warn='#C78124'; danger='#D94C62'; grid='#CBD8E5' }
    snow = @{ bg='#F5F7FB'; card='#FFFFFF'; card2='#EEF2F7'; text='#202A3A'; muted='#737F91'; accent='#5678DB'; cyan='#168BA4'; good='#2A966D'; warn='#BE7A22'; danger='#D65363'; grid='#D9E0E9' }
    mist = @{ bg='#DFEAED'; card='#F1F7F8'; card2='#E7F0F2'; text='#193238'; muted='#607C83'; accent='#4779D4'; cyan='#168E9B'; good='#218D70'; warn='#B9792C'; danger='#CF5868'; grid='#BDD0D5' }
    midnight = @{ bg='#0A0E17'; card='#111827'; card2='#151D2E'; text='#F3F6FD'; muted='#8390A9'; accent='#6EA8FE'; cyan='#31C7E8'; good='#36D399'; warn='#F5B544'; danger='#FF647C'; grid='#243049' }
    graphite = @{ bg='#111315'; card='#191C1F'; card2='#202428'; text='#F1F3F5'; muted='#929AA3'; accent='#80A4FF'; cyan='#49C5D6'; good='#5DD39E'; warn='#F1B557'; danger='#FA6B74'; grid='#30363D' }
    aurora = @{ bg='#091218'; card='#102129'; card2='#142A34'; text='#E9FAFF'; muted='#7AA5B5'; accent='#5F8DFF'; cyan='#28D7CE'; good='#4DDB9E'; warn='#F5C451'; danger='#FF6A8B'; grid='#20414B' }
    light = @{ bg='#EFF3F9'; card='#FFFFFF'; card2='#F7F9FC'; text='#172033'; muted='#68758A'; accent='#3E6FE7'; cyan='#159BB1'; good='#239A68'; warn='#B87714'; danger='#D9495B'; grid='#D8DFEA' }
}
if ($themeName -eq 'custom') { $theme = $themes['frost'] }
elseif ($themes.Contains($themeName)) { $theme = $themes[$themeName] }
else { $themeName = 'frost'; $theme = $themes[$themeName] }

$customTheme = $themeName -eq 'custom'
$background = Parse-Color (Get-Setting $configFile @('bgcolor','backgroundcolor') $theme.bg) ([System.Drawing.ColorTranslator]::FromHtml($theme.bg))
$cardColor = Parse-Color (Get-Setting $configFile @('panelcolor','cardcolor') $theme.card) ([System.Drawing.ColorTranslator]::FromHtml($theme.card))
$cardAltColor = Parse-Color (Get-Setting $configFile @('cardaltcolor') $theme.card2) ([System.Drawing.ColorTranslator]::FromHtml($theme.card2))
$textColor = Parse-Color (Get-Setting $configFile @('textcolor','fg') $theme.text) ([System.Drawing.ColorTranslator]::FromHtml($theme.text))
$mutedColor = Parse-Color (Get-Setting $configFile @('mutedcolor') $theme.muted) ([System.Drawing.ColorTranslator]::FromHtml($theme.muted))
$accentColor = Parse-Color (Get-Setting $configFile @('accentcolor') $theme.accent) ([System.Drawing.ColorTranslator]::FromHtml($theme.accent))
$cyanColor = Parse-Color (Get-Setting $configFile @('cyancolor') $theme.cyan) ([System.Drawing.ColorTranslator]::FromHtml($theme.cyan))
$goodColor = Parse-Color (Get-Setting $configFile @('goodcolor') $theme.good) ([System.Drawing.ColorTranslator]::FromHtml($theme.good))
$warningColor = Parse-Color (Get-Setting $configFile @('warncolor','warningcolor') $theme.warn) ([System.Drawing.ColorTranslator]::FromHtml($theme.warn))
$dangerColor = Parse-Color (Get-Setting $configFile @('dangercolor') $theme.danger) ([System.Drawing.ColorTranslator]::FromHtml($theme.danger))
$gridColor = Parse-Color (Get-Setting $configFile @('gridcolor') $theme.grid) ([System.Drawing.ColorTranslator]::FromHtml($theme.grid))
$customBackground = $background
$currentOpacity = 90

function Set-ConfigValue([string]$key,[string]$value) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $configPath) { $lines.AddRange([System.IO.File]::ReadAllLines($configPath)) }
    $found=$false
    for($i=0;$i -lt $lines.Count;$i++) {
        $line=$lines[$i];$index=$line.IndexOf('=')
        if($index -gt 0 -and $line.Substring(0,$index).Trim().Equals($key,[System.StringComparison]::OrdinalIgnoreCase)){$lines[$i]="$key=$value";$found=$true;break}
    }
    if(-not $found){$lines.Add("$key=$value")}
    [System.IO.File]::WriteAllLines($configPath,$lines,[System.Text.UTF8Encoding]::new($false))
}

function Apply-Theme([string]$name,[System.Drawing.Color]$overrideBackground,[bool]$persist) {
    if($name -eq 'custom') {
        $base=$themes['frost']
        $script:background=$overrideBackground
        $brightness=($overrideBackground.R*299+$overrideBackground.G*587+$overrideBackground.B*114)/1000
        if($brightness -ge 150){
            $script:cardColor=Mix-Color $overrideBackground ([System.Drawing.Color]::White) .74
            $script:cardAltColor=Mix-Color $overrideBackground ([System.Drawing.Color]::White) .48
            $script:textColor=[System.Drawing.ColorTranslator]::FromHtml('#182437')
            $script:mutedColor=[System.Drawing.ColorTranslator]::FromHtml('#66758A')
            $script:gridColor=Mix-Color $overrideBackground ([System.Drawing.ColorTranslator]::FromHtml('#70839A')) .35
        } else {
            $script:cardColor=Mix-Color $overrideBackground ([System.Drawing.Color]::White) .10
            $script:cardAltColor=Mix-Color $overrideBackground ([System.Drawing.Color]::White) .16
            $script:textColor=[System.Drawing.ColorTranslator]::FromHtml('#F3F6FD')
            $script:mutedColor=[System.Drawing.ColorTranslator]::FromHtml('#A1AEC2')
            $script:gridColor=Mix-Color $overrideBackground ([System.Drawing.Color]::White) .24
        }
        $script:accentColor=[System.Drawing.ColorTranslator]::FromHtml($base.accent);$script:cyanColor=[System.Drawing.ColorTranslator]::FromHtml($base.cyan)
        $script:goodColor=[System.Drawing.ColorTranslator]::FromHtml($base.good);$script:warningColor=[System.Drawing.ColorTranslator]::FromHtml($base.warn);$script:dangerColor=[System.Drawing.ColorTranslator]::FromHtml($base.danger)
        $script:customBackground=$overrideBackground
    } else {
        if(-not $themes.Contains($name)){return}
        $t=$themes[$name]
        $script:background=[System.Drawing.ColorTranslator]::FromHtml($t.bg);$script:cardColor=[System.Drawing.ColorTranslator]::FromHtml($t.card);$script:cardAltColor=[System.Drawing.ColorTranslator]::FromHtml($t.card2)
        $script:textColor=[System.Drawing.ColorTranslator]::FromHtml($t.text);$script:mutedColor=[System.Drawing.ColorTranslator]::FromHtml($t.muted);$script:accentColor=[System.Drawing.ColorTranslator]::FromHtml($t.accent)
        $script:cyanColor=[System.Drawing.ColorTranslator]::FromHtml($t.cyan);$script:goodColor=[System.Drawing.ColorTranslator]::FromHtml($t.good);$script:warningColor=[System.Drawing.ColorTranslator]::FromHtml($t.warn);$script:dangerColor=[System.Drawing.ColorTranslator]::FromHtml($t.danger);$script:gridColor=[System.Drawing.ColorTranslator]::FromHtml($t.grid)
    }
    $script:themeName=$name
    if($null -ne $form){$form.BackColor=$background;$form.Invalidate()}
    if($persist){Set-ConfigValue 'theme' $name;if($name -eq 'custom'){Set-ConfigValue 'bgColor' ('#{0:X2}{1:X2}{2:X2}' -f $overrideBackground.R,$overrideBackground.G,$overrideBackground.B)}}
}

$settings = [ordered]@{
    Width = Get-Int (Get-Setting $configFile @('width','w') 452) 452 380 720
    Height = Get-Int (Get-Setting $configFile @('height','h') 588) 588 450 900
    Left = Get-Int (Get-Setting $stateFile @('left','l') (Get-Setting $configFile @('left','l') 48)) 48 -8000 8000
    Top = Get-Int (Get-Setting $stateFile @('top','t') (Get-Setting $configFile @('top','t') 48)) 48 -8000 8000
    Opacity = Get-Int (Get-Setting $configFile @('opacity','windowopacity') 90) 90 55 100
    PollMs = Get-Int (Get-Setting $configFile @('refreshms','interval','intv') 1200) 1200 500 10000
    Drives = [string](Get-Setting $configFile @('drives','drive') 'C:')
    ShowNetwork = Get-Bool (Get-Setting $configFile @('shownetwork','net') 'true') $true
    ShowSystem = Get-Bool (Get-Setting $configFile @('showsystem') 'true') $true
    ShowDiskIo = Get-Bool (Get-Setting $configFile @('showdiskio') 'true') $true
    RememberPosition = Get-Bool (Get-Setting $configFile @('rememberposition','rempos') 'true') $true
    FontName = [string](Get-Setting $configFile @('fontname','font') 'Segoe UI')
    CpuWarn = Get-Int (Get-Setting $configFile @('cpuwarn') 70) 70 1 99
    CpuCrit = Get-Int (Get-Setting $configFile @('cpucrit') 90) 90 2 100
    MemWarn = Get-Int (Get-Setting $configFile @('memwarn') 75) 75 1 99
    MemCrit = Get-Int (Get-Setting $configFile @('memcrit') 90) 90 2 100
    DiskWarn = Get-Int (Get-Setting $configFile @('diskwarn') 80) 80 1 99
    DiskCrit = Get-Int (Get-Setting $configFile @('diskcrit') 92) 92 2 100
    SnapToEdge = Get-Bool (Get-Setting $configFile @('snaptoedge') 'true') $true
    ClampDuringDrag = Get-Bool (Get-Setting $configFile @('clampduringdrag') 'true') $true
    SnapMargin = Get-Int (Get-Setting $configFile @('snapmargin') 6) 6 0 80
    SnapThreshold = Get-Int (Get-Setting $configFile @('snapthreshold') 27) 27 16 240
    ClickThrough = Get-Bool (Get-Setting $configFile @('clickthrough') 'false') $false
    Resizable = Get-Bool (Get-Setting $configFile @('resizable') 'true') $true
    BackgroundImage = [string](Get-Setting $configFile @('backgroundimage') '')
    BackgroundImageMode = [string](Get-Setting $configFile @('backgroundimagemode') 'stretch')
    BackgroundImageOpacity = Get-Int (Get-Setting $configFile @('backgroundimageopacity') 35) 35 0 100
}
if ($settings.BackgroundImageMode -notin @('stretch','fit','fill','tile','center')) { $settings.BackgroundImageMode = 'stretch' }
$currentOpacity = $settings.Opacity
$themePanelOpen=$false
$themeHitAreas=@{}
$themeNames=@('frost','snow','mist','light','midnight','graphite','aurora')

# 新增状态：鼠标穿透 / 自由调整大小 / 背景图片
$script:clickThrough = $settings.ClickThrough
$script:resizeActive = $false
$script:lastEdge = ''
$script:_resize = $null
$edgeThickness = 6
$edgeCursors = @{ e=[System.Windows.Forms.Cursors]::SizeWE; w=[System.Windows.Forms.Cursors]::SizeWE; n=[System.Windows.Forms.Cursors]::SizeNS; s=[System.Windows.Forms.Cursors]::SizeNS; ne=[System.Windows.Forms.Cursors]::SizeNESW; sw=[System.Windows.Forms.Cursors]::SizeNESW; nw=[System.Windows.Forms.Cursors]::SizeNWSE; se=[System.Windows.Forms.Cursors]::SizeNWSE }
$hotkeyId = 0x5050
$script:bgImage = $null
$script:bgImageStream = $null

if (-not (Test-Path -LiteralPath $configPath)) {
    @"
# PerfFloat Monitor v6 configuration
# Themes: midnight | graphite | aurora | light | custom
theme=midnight
width=430
height=560
left=48
top=48
opacity=96
refreshMs=1200
drives=C:
showNetwork=true
showSystem=true
showDiskIo=true
rememberPosition=true
fontName=Segoe UI
cpuWarn=70
cpuCrit=90
memWarn=75
memCrit=90
diskWarn=80
diskCrit=92
# Custom colors are applied when theme=custom
bgColor=#0A0E17
panelColor=#111827
cardAltColor=#151D2E
textColor=#F3F6FD
mutedColor=#8390A9
accentColor=#6EA8FE
cyanColor=#31C7E8
goodColor=#36D399
warnColor=#F5B544
dangerColor=#FF647C
gridColor=#243049
clickThrough=false
resizable=true
backgroundImage=
backgroundImageMode=stretch
backgroundImageOpacity=35
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8
}

$collectorSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Management;
using System.Threading;

public sealed class PerfSnapshot {
    public double Cpu, Memory, Disk, Net, NetDown, NetUp, DiskRead, DiskWrite;
    public double MemoryUsed, MemoryTotal, DiskFree, DiskTotal;
    public int Processes, LogicalProcessors;
    public string Adapter = "N/A", Drives = "N/A", Uptime = "N/A", TopProcess = "N/A";
    public DateTime Time = DateTime.Now;
}

public sealed class PerfCollector : IDisposable {
    readonly object gate = new object();
    readonly string[] wanted;
    volatile bool running;
    Thread thread;
    int interval;
    PerfSnapshot current = new PerfSnapshot();
    PerformanceCounter cpuCounter;
    PerformanceCounter diskReadCounter;
    PerformanceCounter diskWriteCounter;
    int cycle;
    string topProcess = "N/A";

    public PerfCollector(string drives, int intervalMs) {
        interval = Math.Max(500, intervalMs);
        wanted = (drives ?? "C:").Split(new[]{',',';',' '}, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToUpperInvariant().TrimEnd('\\')).Select(x => x.Length == 1 ? x + ":" : x).Distinct().ToArray();
        try { cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total", true); cpuCounter.NextValue(); } catch {}
        try { diskReadCounter = new PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec", "_Total", true); diskReadCounter.NextValue(); } catch {}
        try { diskWriteCounter = new PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total", true); diskWriteCounter.NextValue(); } catch {}
    }

    public void Start() { if (running) return; running = true; thread = new Thread(Loop); thread.IsBackground = true; thread.Name = "PerfFloat Collector"; thread.Start(); }
    void Loop() { while (running) { try { Collect(); } catch {} for (int i=0; running && i<interval/100; i++) Thread.Sleep(100); } }
    public PerfSnapshot GetSnapshot() { lock(gate) return current; }

    static double N(object value) { if (value == null) return 0; double d; return double.TryParse(value.ToString(), out d) ? d : 0; }
    static string FmtUptime(double seconds) { var t = TimeSpan.FromSeconds(Math.Max(0, seconds)); return t.Days > 0 ? String.Format("{0}d {1}h {2}m", t.Days, t.Hours, t.Minutes) : String.Format("{0}h {1}m", (int)t.TotalHours, t.Minutes); }

    void Collect() {
        var s = new PerfSnapshot();
        cycle++;
        s.TopProcess = topProcess;
        try { s.Cpu = cpuCounter != null ? cpuCounter.NextValue() : 0; } catch {}
        try {
            using (var searcher = new ManagementObjectSearcher("SELECT TotalVisibleMemorySize,FreePhysicalMemory,LastBootUpTime,NumberOfProcesses FROM Win32_OperatingSystem"))
            foreach (ManagementObject x in searcher.Get()) {
                var total = N(x["TotalVisibleMemorySize"]) * 1024;
                var free = N(x["FreePhysicalMemory"]) * 1024;
                s.MemoryTotal = total; s.MemoryUsed = Math.Max(0, total-free); s.Memory = total > 0 ? s.MemoryUsed/total*100 : 0;
                s.Processes = (int)N(x["NumberOfProcesses"]);
                try { var boot = ManagementDateTimeConverter.ToDateTime(Convert.ToString(x["LastBootUpTime"])); s.Uptime = FmtUptime((DateTime.Now-boot).TotalSeconds); } catch {}
                break;
            }
        } catch {}
        try {
            var names = new List<string>();
            using (var searcher = new ManagementObjectSearcher("SELECT DeviceID,Size,FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3"))
            foreach (ManagementObject x in searcher.Get()) {
                string id = Convert.ToString(x["DeviceID"]).ToUpperInvariant();
                if (wanted.Length > 0 && !wanted.Contains(id)) continue;
                double size=N(x["Size"]), free=N(x["FreeSpace"]); s.DiskTotal += size; s.DiskFree += free; names.Add(id);
            }
            s.Drives = names.Count > 0 ? String.Join(" ", names) : "N/A";
            s.Disk = s.DiskTotal > 0 ? (s.DiskTotal-s.DiskFree)/s.DiskTotal*100 : 0;
        } catch {}
        try { s.DiskRead = diskReadCounter != null ? diskReadCounter.NextValue() : 0; } catch {}
        try { s.DiskWrite = diskWriteCounter != null ? diskWriteCounter.NextValue() : 0; } catch {}
        try {
            using (var searcher = new ManagementObjectSearcher("SELECT Name,BytesReceivedPersec,BytesSentPersec,CurrentBandwidth FROM Win32_PerfFormattedData_Tcpip_NetworkInterface")) {
                double best=0;
                foreach (ManagementObject x in searcher.Get()) {
                    string name=Convert.ToString(x["Name"]);
                    if (name.IndexOf("loopback",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("isatap",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("teredo",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("virtual",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("vmware",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("hyper-v",StringComparison.OrdinalIgnoreCase)>=0) continue;
                    double down=N(x["BytesReceivedPersec"]), up=N(x["BytesSentPersec"]), total=down+up;
                    if(total>best){best=total;s.NetDown=down;s.NetUp=up;s.Adapter=name;double bw=N(x["CurrentBandwidth"]);s.Net=bw>0?Math.Min(100,total*8/bw*100):0;}
                }
            }
        } catch {}
        try { s.LogicalProcessors = Environment.ProcessorCount; }
        catch {}
        if (cycle == 1 || cycle % 5 == 0) {
            try {
                var p = Process.GetProcesses().Where(x => x.Id != Process.GetCurrentProcess().Id).OrderByDescending(x => { try { return x.WorkingSet64; } catch { return 0; } }).FirstOrDefault();
                if (p != null) { topProcess = p.ProcessName; s.TopProcess = topProcess; }
            } catch {}
        }
        s.Time=DateTime.Now;
        lock(gate) current=s;
    }
    public void Dispose(){running=false;try{if(thread!=null&&thread.IsAlive)thread.Join(700);}catch{}try{if(cpuCounter!=null)cpuCounter.Dispose();}catch{}try{if(diskReadCounter!=null)diskReadCounter.Dispose();}catch{}try{if(diskWriteCounter!=null)diskWriteCounter.Dispose();}catch{}}
}
'@
Add-Type -TypeDefinition $collectorSource -ReferencedAssemblies @('System.dll','System.Core.dll','System.Management.dll')

function New-RoundedPath([System.Drawing.RectangleF]$rect, [float]$radius) {
    $diameter = $radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.Left, $rect.Top, $diameter, $diameter, 180, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Top, $diameter, $diameter, 270, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($rect.Left, $rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Mix-Color([System.Drawing.Color]$a, [System.Drawing.Color]$b, [double]$amount) {
    $amount = [Math]::Min(1, [Math]::Max(0, $amount))
    return [System.Drawing.Color]::FromArgb(
        [int]($a.A + ($b.A-$a.A)*$amount),
        [int]($a.R + ($b.R-$a.R)*$amount),
        [int]($a.G + ($b.G-$a.G)*$amount),
        [int]($a.B + ($b.B-$a.B)*$amount))
}

function Format-Bytes([double]$value) {
    if ($value -lt 1024) { return '{0:F0} B' -f $value }
    if ($value -lt 1MB) { return '{0:F1} KB' -f ($value/1KB) }
    if ($value -lt 1GB) { return '{0:F1} MB' -f ($value/1MB) }
    if ($value -lt 1TB) { return '{0:F1} GB' -f ($value/1GB) }
    return '{0:F1} TB' -f ($value/1TB)
}

function Threshold-Color([double]$value, [int]$warn, [int]$crit) {
    if ($value -ge $crit) { return $dangerColor }
    if ($value -ge $warn) { return $warningColor }
    return $goodColor
}

if ('HotKeyForm' -as [type]) { $form = New-Object HotKeyForm } else { $form = New-Object System.Windows.Forms.Form }
$form.Text = 'PerfFloat Monitor'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $background
$form.Width = 340
$form.Height = 300
$form.Left = $settings.Left
$form.Top = $settings.Top
$form.Opacity = $settings.Opacity / 100.0
$form.MinimumSize = New-Object System.Drawing.Size(220,130)
$form.MaximumSize = New-Object System.Drawing.Size(720,900)
$form.KeyPreview = $true
$setStyle = $form.GetType().GetMethod('SetStyle',[System.Reflection.BindingFlags]'Instance,NonPublic')
$styleValue = [int][System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor [int][System.Windows.Forms.ControlStyles]::UserPaint -bor [int][System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor [int][System.Windows.Forms.ControlStyles]::ResizeRedraw
$setStyle.Invoke($form,@([System.Windows.Forms.ControlStyles]$styleValue,$true)) | Out-Null

$normalFont = New-Object System.Drawing.Font($settings.FontName,9,[System.Drawing.FontStyle]::Regular)
$smallFont = New-Object System.Drawing.Font($settings.FontName,8,[System.Drawing.FontStyle]::Regular)
$titleFont = New-Object System.Drawing.Font($settings.FontName,12,[System.Drawing.FontStyle]::Bold)
$metricFont = New-Object System.Drawing.Font($settings.FontName,20,[System.Drawing.FontStyle]::Bold)
$labelFont = New-Object System.Drawing.Font($settings.FontName,9,[System.Drawing.FontStyle]::Bold)
$chipFont = New-Object System.Drawing.Font($settings.FontName,8,[System.Drawing.FontStyle]::Bold)

$collector = New-Object PerfCollector($settings.Drives,$settings.PollMs)
$collector.Start()
$target = $collector.GetSnapshot()
$display = [ordered]@{ Cpu=0.0; Memory=0.0; Disk=0.0; Net=0.0; NetDown=0.0; NetUp=0.0; DiskRead=0.0; DiskWrite=0.0 }
$histories = @{
    Cpu = New-Object 'System.Collections.Generic.List[double]'
    Memory = New-Object 'System.Collections.Generic.List[double]'
    Disk = New-Object 'System.Collections.Generic.List[double]'
    Net = New-Object 'System.Collections.Generic.List[double]'
}
$lastHistoryAt = [DateTime]::MinValue
$hoverButton = ''
$pressedButton = ''
$dragging = $false
$dragOffset = [System.Drawing.Point]::Empty
$exiting = $false
$layoutMode=[string](Get-Setting $stateFile @('layout') (Get-Setting $configFile @('defaultlayout') 'gamebar'))
if($layoutMode -notin @('gamebar','grid','strip','mini','details')){$layoutMode=if((Get-Bool (Get-Setting $stateFile @('compact') 'false') $false)){'mini'}else{'gamebar'}}
$selectedMetric=[string](Get-Setting $stateFile @('selectedmetric') 'Cpu')
if($selectedMetric -notin @('Cpu','Memory','Disk','Net')){$selectedMetric='Cpu'}
$layoutPanelOpen=$false
$layoutHitAreas=@{}
$metricHitAreas=@{}
$layoutModes=@('gamebar','grid','strip','mini','details')
$layoutSizes=@{gamebar=@(300,260);grid=@(390,390);strip=@(500,100);mini=@(260,190);details=@($settings.Width,$settings.Height)}
$targetWidth=[double]$layoutSizes[$layoutMode][0];$targetHeight=[double]$layoutSizes[$layoutMode][1]
$form.Width=[int]$targetWidth;$form.Height=[int]$targetHeight
$compact=$layoutMode -eq 'mini'
$normalHeight=$settings.Height
$compactHeight=170
$layout = @{}
$snapAnchor=[string](Get-Setting $stateFile @('snapanchor') '')
$snapScreen=[string](Get-Setting $stateFile @('screendevice') '')

function Get-WorkArea([System.Drawing.Point]$point) {
    $screen=[System.Windows.Forms.Screen]::FromPoint($point)
    $area=$screen.WorkingArea
    $m=$settings.SnapMargin
    return [System.Drawing.Rectangle]::new($area.Left+$m,$area.Top+$m,[Math]::Max(1,$area.Width-$m*2),[Math]::Max(1,$area.Height-$m*2))
}
function Clamp-Location([int]$left,[int]$top,[int]$width,[int]$height,[System.Drawing.Rectangle]$area) {
    $maxLeft=[Math]::Max($area.Left,$area.Right-$width);$maxTop=[Math]::Max($area.Top,$area.Bottom-$height)
    return [System.Drawing.Point]::new([Math]::Min($maxLeft,[Math]::Max($area.Left,$left)),[Math]::Min($maxTop,[Math]::Max($area.Top,$top)))
}
function Get-AnchorPoint([string]$anchor,[System.Drawing.Rectangle]$area,[int]$width,[int]$height) {
    $left=$area.Left;$right=$area.Right-$width;$top=$area.Top;$bottom=$area.Bottom-$height;$centerX=$area.Left+[int](($area.Width-$width)/2);$centerY=$area.Top+[int](($area.Height-$height)/2)
    switch($anchor){'top-left'{return [System.Drawing.Point]::new($left,$top)}'top-center'{return [System.Drawing.Point]::new($centerX,$top)}'top-right'{return [System.Drawing.Point]::new($right,$top)}'middle-left'{return [System.Drawing.Point]::new($left,$centerY)}'middle-right'{return [System.Drawing.Point]::new($right,$centerY)}'bottom-left'{return [System.Drawing.Point]::new($left,$bottom)}'bottom-center'{return [System.Drawing.Point]::new($centerX,$bottom)}'bottom-right'{return [System.Drawing.Point]::new($right,$bottom)}default{return [System.Drawing.Point]::new($left,$top)}}
}
function Get-NearestAnchor([System.Drawing.Point]$location,[System.Drawing.Rectangle]$area,[int]$width,[int]$height) {
    $best='';$bestDistance=[double]::MaxValue
    foreach($name in @('top-left','top-center','top-right','middle-left','middle-right','bottom-left','bottom-center','bottom-right')){$p=Get-AnchorPoint $name $area $width $height;$dx=$location.X-$p.X;$dy=$location.Y-$p.Y;$distance=[Math]::Sqrt($dx*$dx+$dy*$dy);if($distance -lt $bestDistance){$bestDistance=$distance;$best=$name}}
    if($bestDistance -le $settings.SnapThreshold){return $best};return ''
}
function Ensure-OnScreen([bool]$applyAnchor) {
    $center=[System.Drawing.Point]::new($form.Left+[int]($form.Width/2),$form.Top+[int]($form.Height/2));$area=Get-WorkArea $center
    if($applyAnchor -and $snapAnchor){$form.Location=Get-AnchorPoint $snapAnchor $area $form.Width $form.Height}else{$form.Location=Clamp-Location $form.Left $form.Top $form.Width $form.Height $area}
    $script:snapScreen=[System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($form.Left,$form.Top)).DeviceName
}
function Finish-Drag {
    $script:dragging=$false;$form.Capture=$false;$center=[System.Drawing.Point]::new($form.Left+[int]($form.Width/2),$form.Top+[int]($form.Height/2));$area=Get-WorkArea $center
    $clamped=Clamp-Location $form.Left $form.Top $form.Width $form.Height $area;$form.Location=$clamped
    if($settings.SnapToEdge){$nearest=Get-NearestAnchor $clamped $area $form.Width $form.Height;if($nearest){$script:snapAnchor=$nearest;$form.Location=Get-AnchorPoint $nearest $area $form.Width $form.Height}else{$script:snapAnchor=''}}else{$script:snapAnchor=''}
    $script:snapScreen=[System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($form.Left,$form.Top)).DeviceName;Save-State
}

function Set-ClickThrough {
    if (-not $form.IsHandleCreated) { return }
    try {
        $ex = [PerfFloatWin32]::GetWindowLong($form.Handle, [PerfFloatWin32]::GWL_EXSTYLE)
        if ($form.GetType().Name -eq 'HotKeyForm') {
            Get-Layout
            $passRect = $layout.ClickThrough
            $form.PassThrough = $script:clickThrough
            $form.PassThroughLeft = [int][Math]::Floor($passRect.X)
            $form.PassThroughTop = [int][Math]::Floor($passRect.Y)
            $form.PassThroughRight = [int][Math]::Ceiling($passRect.Right)
            $form.PassThroughBottom = [int][Math]::Ceiling($passRect.Bottom)
            if ($script:clickThrough) {
                if (-not $form.EnablePassThroughButtonHook()) {
                    $script:clickThrough = $false
                    $form.PassThrough = $false
                    Set-ConfigValue 'clickThrough' 'false'
                }
            } else {
                $form.DisablePassThroughButtonHook()
            }
        }
        if ($script:clickThrough) { $ex = $ex -bor [PerfFloatWin32]::WS_EX_TRANSPARENT }
        else { $ex = $ex -band (-bnot [PerfFloatWin32]::WS_EX_TRANSPARENT) }
        [PerfFloatWin32]::SetWindowLong($form.Handle, [PerfFloatWin32]::GWL_EXSTYLE, $ex) | Out-Null
        try { if ($script:mClick) { $script:mClick.Checked = $script:clickThrough } } catch { }
    } catch { }
}
function Toggle-ClickThrough {
    $script:clickThrough = -not $script:clickThrough
    try { Set-ConfigValue 'clickThrough' $(if($script:clickThrough){'true'}else{'false'}) } catch { }
    Set-ClickThrough
    try { if ($script:mClick) { $script:mClick.Checked = $script:clickThrough } } catch { }
    try { $form.Invalidate() } catch { }
}
function Hit-ResizeEdge([System.Drawing.Point]$p) {
    if (-not $settings.Resizable -or $script:clickThrough) { return '' }
    $x=[single]$p.X; $y=[single]$p.Y
    $w=$form.ClientSize.Width; $h=$form.ClientSize.Height
    $t=[single]$edgeThickness
    $onN = $y -le $t; $onS = $y -ge ($h - $t)
    $onE = $x -ge ($w - $t); $onW = $x -le $t
    if ($onN -and $onE) { return 'ne' }
    if ($onN -and $onW) { return 'nw' }
    if ($onS -and $onE) { return 'se' }
    if ($onS -and $onW) { return 'sw' }
    if ($onE) { return 'e' }
    if ($onW) { return 'w' }
    if ($onN) { return 'n' }
    if ($onS) { return 's' }
    return ''
}
function Finish-Resize {
    if (-not $script:_resize) { return }
    $script:_resize = $null
    $form.Capture = $false
    $script:resizeActive = $false
    Save-State
    try { Set-ConfigValue 'width' "$($form.Width)"; Set-ConfigValue 'height' "$($form.Height)" } catch { }
}
function Load-BackgroundImage([string]$imagePath) {
    if ([string]::IsNullOrWhiteSpace($imagePath)) { $imagePath = [string]$settings.BackgroundImage }
    if ([string]::IsNullOrWhiteSpace($imagePath)) {
        if ($script:bgImage) { try { $script:bgImage.Dispose() } catch { } }
        $script:bgImage = $null
        return $false
    }
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { return $false }
    $stream = $null
    $source = $null
    $candidate = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($imagePath)
        $stream = New-Object System.IO.MemoryStream (,$bytes)
        $source = [System.Drawing.Image]::FromStream($stream,$true,$true)
        if ($source.Width -lt 1 -or $source.Height -lt 1 -or ([long]$source.Width * [long]$source.Height) -gt 100000000) { throw 'Invalid image dimensions.' }
        $candidate = New-Object System.Drawing.Bitmap($source)
    } catch {
        if ($candidate) { try { $candidate.Dispose() } catch { } }
        if ($source) { try { $source.Dispose() } catch { } }
        if ($stream) { try { $stream.Dispose() } catch { } }
        return $false
    }
    if ($source) { try { $source.Dispose() } catch { } }
    if ($stream) { try { $stream.Dispose() } catch { } }
    $previous = $script:bgImage
    $script:bgImage = $candidate
    if ($previous) { try { $previous.Dispose() } catch { } }
    return $true
}
function Draw-BackgroundImage($g) {
    $img = $script:bgImage
    if (-not $img) { return }
    $ia = $null
    $cm = $null
    try {
        $w = $form.ClientSize.Width
        $h = $form.ClientSize.Height
        if ($w -lt 1 -or $h -lt 1 -or $img.Width -lt 1 -or $img.Height -lt 1) { return }
        $opacity = [Math]::Min(1.0, [Math]::Max(0.0, $settings.BackgroundImageOpacity / 100.0))
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix33 = $opacity
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $iw = [double]$img.Width
        $ih = [double]$img.Height
        switch ($settings.BackgroundImageMode) {
            'fill' {
                $scale = [Math]::Max($w / $iw,$h / $ih)
                $dw = [Math]::Max(1,[int]($iw * $scale)); $dh = [Math]::Max(1,[int]($ih * $scale))
                $g.DrawImage($img,[System.Drawing.Rectangle]::new([int](($w-$dw)/2),[int](($h-$dh)/2),$dw,$dh),[single]0,[single]0,[single]$img.Width,[single]$img.Height,[System.Drawing.GraphicsUnit]::Pixel,$ia)
            }
            'fit' {
                $scale = [Math]::Min($w / $iw,$h / $ih)
                $dw = [Math]::Max(1,[int]($iw * $scale)); $dh = [Math]::Max(1,[int]($ih * $scale))
                $g.DrawImage($img,[System.Drawing.Rectangle]::new([int](($w-$dw)/2),[int](($h-$dh)/2),$dw,$dh),[single]0,[single]0,[single]$img.Width,[single]$img.Height,[System.Drawing.GraphicsUnit]::Pixel,$ia)
            }
            'tile' {
                for ($ty=0; $ty -lt $h; $ty += $img.Height) {
                    for ($tx=0; $tx -lt $w; $tx += $img.Width) {
                        $g.DrawImage($img,[System.Drawing.Rectangle]::new($tx,$ty,$img.Width,$img.Height),[single]0,[single]0,[single]$img.Width,[single]$img.Height,[System.Drawing.GraphicsUnit]::Pixel,$ia)
                    }
                }
            }
            'center' {
                $g.DrawImage($img,[System.Drawing.Rectangle]::new([int](($w-$iw)/2),[int](($h-$ih)/2),$img.Width,$img.Height),[single]0,[single]0,[single]$img.Width,[single]$img.Height,[System.Drawing.GraphicsUnit]::Pixel,$ia)
            }
            default {
                $g.DrawImage($img,[System.Drawing.Rectangle]::new(0,0,$w,$h),[single]0,[single]0,[single]$img.Width,[single]$img.Height,[System.Drawing.GraphicsUnit]::Pixel,$ia)
            }
        }
    } catch {
        if ($script:bgImage -eq $img) { $script:bgImage = $null }
        try { $img.Dispose() } catch { }
    } finally {
        if ($ia) { $ia.Dispose() }

    }
}

function Get-Layout {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $margin = 14
    $header = [System.Drawing.RectangleF]::new($margin,10,$w-$margin*2,38)
    $button = 28
    $script:layout = @{
        Header=$header
        LayoutButton=[System.Drawing.RectangleF]::new($w-$margin-146,14,$button,$button)
        Theme=[System.Drawing.RectangleF]::new($w-$margin-116,14,$button,$button)
        ClickThrough=[System.Drawing.RectangleF]::new($w-$margin-86,14,$button,$button)
        Compact=[System.Drawing.RectangleF]::new($w-$margin-56,14,$button,$button)
        Close=[System.Drawing.RectangleF]::new($w-$margin-26,14,$button,$button)
        ThemePanel=[System.Drawing.RectangleF]::new([Math]::Max($margin,$w-358),52,[Math]::Min(344,$w-$margin*2),460)
        LayoutPanel=[System.Drawing.RectangleF]::new([Math]::Max($margin,$w-318),52,[Math]::Min(304,$w-$margin*2),282)
        Content=[System.Drawing.RectangleF]::new($margin,58,$w-$margin*2,$h-72)
    }
}

function Draw-RoundedRect($g, $brush, $pen, [System.Drawing.RectangleF]$rect, [float]$radius) {
    $path = New-RoundedPath $rect $radius
    if ($null -ne $brush) { $g.FillPath($brush,$path) }
    if ($null -ne $pen) { $g.DrawPath($pen,$path) }
    $path.Dispose()
}

function Draw-Text($g,[string]$text,$font,$brush,[float]$x,[float]$y,[float]$width,[System.Drawing.StringAlignment]$alignment) {
    if ($width -le 0) { return }
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = $alignment
    $format.LineAlignment = [System.Drawing.StringAlignment]::Near
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $g.DrawString($text,$font,$brush,[System.Drawing.RectangleF]::new($x,$y,$width,$font.Height+5),$format)
    $format.Dispose()
}

function Draw-Button($g,[string]$name,[string]$glyph,[System.Drawing.RectangleF]$rect) {
    $isHover = $hoverButton -eq $name
    $isDown = $pressedButton -eq $name
    $isActive = $name -eq 'clickthrough' -and $script:clickThrough
    $fill = if ($isDown) { Mix-Color $cardAltColor $accentColor .30 } elseif ($isActive) { Mix-Color $cardAltColor $accentColor .24 } elseif ($isHover) { Mix-Color $cardAltColor $accentColor .14 } else { $cardAltColor }
    $fillBrush = New-Object System.Drawing.SolidBrush($fill)
    $borderPen = New-Object System.Drawing.Pen((Mix-Color $gridColor $accentColor $(if($isHover){.4}else{0})),1)
    Draw-RoundedRect $g $fillBrush $borderPen $rect 8
    $glyphBrush = New-Object System.Drawing.SolidBrush($(if($isHover){$textColor}else{$mutedColor}))
    Draw-Text $g $glyph $labelFont $glyphBrush $rect.X ($rect.Y+5) $rect.Width ([System.Drawing.StringAlignment]::Center)
    $glyphBrush.Dispose(); $borderPen.Dispose(); $fillBrush.Dispose()
}

function Draw-ThemePanel($g) {
    $script:themeHitAreas=@{}
    $rect=$layout.ThemePanel
    $shadow=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38,33,48,68));Draw-RoundedRect $g $shadow $null ([System.Drawing.RectangleF]::new($rect.X+3,$rect.Y+5,$rect.Width,$rect.Height)) 16;$shadow.Dispose()
    $fill=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(248,$cardColor));$border=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $fill $border $rect 16
    $tb=New-Object System.Drawing.SolidBrush($textColor);$mb=New-Object System.Drawing.SolidBrush($mutedColor)
    Draw-Text $g 'THEME' $labelFont $tb ($rect.X+16) ($rect.Y+13) 100 ([System.Drawing.StringAlignment]::Near)
    Draw-Text $g 'Choose a style' $smallFont $mb ($rect.X+86) ($rect.Y+15) 130 ([System.Drawing.StringAlignment]::Near)
    $cols=3;$gap=8;$cellW=($rect.Width-32-$gap*2)/3;$cellH=61
    for($i=0;$i -lt $themeNames.Count;$i++){
        $row=[Math]::Floor($i/$cols);$col=$i%$cols;$name=$themeNames[$i];$x=$rect.X+16+$col*($cellW+$gap);$y=$rect.Y+43+$row*($cellH+$gap);$cell=[System.Drawing.RectangleF]::new($x,$y,$cellW,$cellH);$script:themeHitAreas["theme:$name"]=$cell
        $t=$themes[$name];$bgc=[System.Drawing.ColorTranslator]::FromHtml($t.bg);$cc=[System.Drawing.ColorTranslator]::FromHtml($t.card);$ac=[System.Drawing.ColorTranslator]::FromHtml($t.accent)
        $selected=$themeName -eq $name;$cb=New-Object System.Drawing.SolidBrush($cc);$cp=New-Object System.Drawing.Pen($(if($selected){$accentColor}else{$gridColor}),$(if($selected){2}else{1}));Draw-RoundedRect $g $cb $cp $cell 10
        $sw=New-Object System.Drawing.SolidBrush($bgc);Draw-RoundedRect $g $sw $null ([System.Drawing.RectangleF]::new($x+8,$y+8,$cellW-16,23)) 6;$sw.Dispose()
        $ab=New-Object System.Drawing.SolidBrush($ac);$g.FillEllipse($ab,$x+$cellW-21,$y+14,8,8);$ab.Dispose()
        Draw-Text $g $name.ToUpperInvariant() $chipFont $mb ($x+8) ($y+38) ($cellW-16) ([System.Drawing.StringAlignment]::Near)
        $cp.Dispose();$cb.Dispose()
    }
    $bx=$rect.X+16; $bw=$rect.Width-32
    $by=$rect.Y+252
    Draw-Text $g 'BACKGROUND IMAGE' $chipFont $tb $bx $by $bw ([System.Drawing.StringAlignment]::Near)
    $pick=[System.Drawing.RectangleF]::new($bx,$by+22,90,26);$clr=[System.Drawing.RectangleF]::new($bx+100,$by+22,70,26)
    $script:themeHitAreas['bgimage:pick']=$pick;$script:themeHitAreas['bgimage:clear']=$clr
    foreach($item in @(@($pick,'PICK IMAGE'),@($clr,'CLEAR'))){$b=New-Object System.Drawing.SolidBrush($cardAltColor);$p=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $b $p $item[0] 8;Draw-Text $g $item[1] $chipFont $tb $item[0].X ($item[0].Y+7) $item[0].Width ([System.Drawing.StringAlignment]::Center);$p.Dispose();$b.Dispose()}
    $my=$by+56
    Draw-Text $g 'MODE' $chipFont $mb $bx $my 50 ([System.Drawing.StringAlignment]::Near)
    $modeBtn=[System.Drawing.RectangleF]::new($bx+54,$my,$bw-54,26);$script:themeHitAreas['bgimage:mode']=$modeBtn
    $b=New-Object System.Drawing.SolidBrush($cardAltColor);$p=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $b $p $modeBtn 8;Draw-Text $g ($settings.BackgroundImageMode.ToUpperInvariant()) $chipFont $tb $modeBtn.X ($modeBtn.Y+7) $modeBtn.Width ([System.Drawing.StringAlignment]::Center);$p.Dispose();$b.Dispose()
    $oy=$by+88
    Draw-Text $g 'OPAC' $chipFont $mb $bx $oy 50 ([System.Drawing.StringAlignment]::Near)
    $bminus=[System.Drawing.RectangleF]::new($bx+54,$oy,30,26);$bplus=[System.Drawing.RectangleF]::new($bx+96,$oy,30,26)
    $script:themeHitAreas['bgopacity-']=$bminus;$script:themeHitAreas['bgopacity+']=$bplus
    foreach($item in @(@($bminus,'-'),@($bplus,'+'))){$b=New-Object System.Drawing.SolidBrush($cardAltColor);$p=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $b $p $item[0] 8;Draw-Text $g $item[1] $chipFont $tb $item[0].X ($item[0].Y+7) $item[0].Width ([System.Drawing.StringAlignment]::Center);$p.Dispose();$b.Dispose()}
    Draw-Text $g ("$($settings.BackgroundImageOpacity)%") $labelFont $tb ($bx+132) ($oy+5) 44 ([System.Drawing.StringAlignment]::Near)
    $bottom=$rect.Bottom-92
    $custom=[System.Drawing.RectangleF]::new($rect.X+16,$bottom,$rect.Width-32,34);$script:themeHitAreas['custom']=$custom
    $cb=New-Object System.Drawing.SolidBrush($cardAltColor);$cp=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $cb $cp $custom 9
    $sample=New-Object System.Drawing.SolidBrush($customBackground);Draw-RoundedRect $g $sample $null ([System.Drawing.RectangleF]::new($custom.X+9,$custom.Y+8,18,18)) 5;$sample.Dispose()
    Draw-Text $g 'CUSTOM BACKGROUND' $chipFont $tb ($custom.X+35) ($custom.Y+9) ($custom.Width-44) ([System.Drawing.StringAlignment]::Near);$cp.Dispose();$cb.Dispose()
    $y=$rect.Bottom-46;$minus=[System.Drawing.RectangleF]::new($rect.X+16,$y,30,28);$plus=[System.Drawing.RectangleF]::new($rect.X+104,$y,30,28);$reset=[System.Drawing.RectangleF]::new($rect.Right-80,$y,64,28)
    $script:themeHitAreas['opacity-']=$minus;$script:themeHitAreas['opacity+']=$plus;$script:themeHitAreas['reset']=$reset
    foreach($item in @(@($minus,'-'),@($plus,'+'),@($reset,'RESET'))){$b=New-Object System.Drawing.SolidBrush($cardAltColor);$p=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $b $p $item[0] 8;Draw-Text $g $item[1] $chipFont $tb $item[0].X ($item[0].Y+7) $item[0].Width ([System.Drawing.StringAlignment]::Center);$p.Dispose();$b.Dispose()}
    Draw-Text $g ("$currentOpacity%") $labelFont $tb ($rect.X+48) ($y+5) 54 ([System.Drawing.StringAlignment]::Center)
    $mb.Dispose();$tb.Dispose();$border.Dispose();$fill.Dispose()
}

function Hit-TestThemePanel([System.Drawing.Point]$point) {
    $x=[single]$point.X;$y=[single]$point.Y
    foreach($key in $themeHitAreas.Keys){if($themeHitAreas[$key].Contains($x,$y)){return [string]$key}}
    return ''
}

function Draw-LayoutPanel($g) {
    $script:layoutHitAreas=@{};$rect=$layout.LayoutPanel
    $shadow=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38,33,48,68));Draw-RoundedRect $g $shadow $null ([System.Drawing.RectangleF]::new($rect.X+3,$rect.Y+5,$rect.Width,$rect.Height)) 16;$shadow.Dispose()
    $fill=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(248,$cardColor));$border=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $fill $border $rect 16
    $tb=New-Object System.Drawing.SolidBrush($textColor);$mb=New-Object System.Drawing.SolidBrush($mutedColor);Draw-Text $g 'LAYOUT' $labelFont $tb ($rect.X+16) ($rect.Y+14) 90 ([System.Drawing.StringAlignment]::Near)
    $names=@{gamebar='GAME BAR';grid='GRID';strip='STRIP';mini='MINI';details='DETAILS'};$sizes=@{gamebar='300 x 260';grid='390 x 390';strip='500 x 100';mini='260 x 190';details='452 x 588'}
    $gap=8;$cellW=($rect.Width-40)/2;$cellH=66
    for($i=0;$i -lt $layoutModes.Count;$i++){$row=[Math]::Floor($i/2);$col=$i%2;$name=$layoutModes[$i];$x=$rect.X+16+$col*($cellW+$gap);$y=$rect.Y+43+$row*($cellH+$gap);$cell=[System.Drawing.RectangleF]::new($x,$y,$cellW,$cellH);$script:layoutHitAreas["layout:$name"]=$cell
        $b=New-Object System.Drawing.SolidBrush($cardAltColor);$p=New-Object System.Drawing.Pen($(if($layoutMode -eq $name){$accentColor}else{$gridColor}),$(if($layoutMode -eq $name){2}else{1}));Draw-RoundedRect $g $b $p $cell 10
        $preview=[System.Drawing.RectangleF]::new($x+8,$y+8,42,28);$pb=New-Object System.Drawing.SolidBrush((Mix-Color $cardAltColor $accentColor .10));$pp=New-Object System.Drawing.Pen($accentColor,1);Draw-RoundedRect $g $pb $pp $preview 4
        if($name -eq 'gamebar'){$g.DrawLine($pp,$preview.X+13,$preview.Y+3,$preview.X+13,$preview.Bottom-3);$g.DrawLine($pp,$preview.X+17,$preview.Y+15,$preview.Right-3,$preview.Y+15)}
        elseif($name -eq 'grid'){$g.DrawLine($pp,$preview.X+21,$preview.Y+3,$preview.X+21,$preview.Bottom-3);$g.DrawLine($pp,$preview.X+3,$preview.Y+14,$preview.Right-3,$preview.Y+14)}
        elseif($name -eq 'strip'){$g.DrawLine($pp,$preview.X+10,$preview.Y+3,$preview.X+10,$preview.Bottom-3);$g.DrawLine($pp,$preview.X+21,$preview.Y+3,$preview.X+21,$preview.Bottom-3);$g.DrawLine($pp,$preview.X+31,$preview.Y+3,$preview.X+31,$preview.Bottom-3)}
        elseif($name -eq 'mini'){$g.DrawLine($pp,$preview.X+3,$preview.Y+7,$preview.Right-3,$preview.Y+7);$g.DrawLine($pp,$preview.X+3,$preview.Y+14,$preview.Right-3,$preview.Y+14);$g.DrawLine($pp,$preview.X+3,$preview.Y+21,$preview.Right-3,$preview.Y+21)}
        else{$g.DrawRectangle($pp,$preview.X+4,$preview.Y+4,14,9);$g.DrawRectangle($pp,$preview.X+23,$preview.Y+4,14,9);$g.DrawRectangle($pp,$preview.X+4,$preview.Y+17,33,7)}
        $pp.Dispose();$pb.Dispose();Draw-Text $g $names[$name] $chipFont $tb ($x+58) ($y+13) ($cellW-64) ([System.Drawing.StringAlignment]::Near);Draw-Text $g $sizes[$name] $smallFont $mb ($x+58) ($y+34) ($cellW-64) ([System.Drawing.StringAlignment]::Near);$p.Dispose();$b.Dispose()}
    $mb.Dispose();$tb.Dispose();$border.Dispose();$fill.Dispose()
}
function Hit-TestLayoutPanel([System.Drawing.Point]$point){$x=[single]$point.X;$y=[single]$point.Y;foreach($key in $layoutHitAreas.Keys){if($layoutHitAreas[$key].Contains($x,$y)){return [string]$key}};return ''}

function Get-MetricData([string]$name){switch($name){'Cpu'{return @('CPU',$display.Cpu,$histories.Cpu,(Threshold-Color $display.Cpu $settings.CpuWarn $settings.CpuCrit),"$($target.LogicalProcessors) cores")};'Memory'{return @('MEM',$display.Memory,$histories.Memory,(Threshold-Color $display.Memory $settings.MemWarn $settings.MemCrit),"$(Format-Bytes $target.MemoryUsed) used")};'Disk'{return @('DSK',$display.Disk,$histories.Disk,(Threshold-Color $display.Disk $settings.DiskWarn $settings.DiskCrit),"$(Format-Bytes $target.DiskFree) free")};default{return @('NET',$display.Net,$histories.Net,$cyanColor,"$(Format-Bytes $display.NetDown)/s down")}}}

function Draw-GameBarLayout($g,$content,$titleBrush,$mutedBrush){
    $script:metricHitAreas=@{};$leftW=92;$chart=[System.Drawing.RectangleF]::new($content.X+$leftW+10,$content.Y,$content.Width-$leftW-10,$content.Height-28);$names=@('Cpu','Memory','Disk','Net');$rowH=42
    for($i=0;$i -lt 4;$i++){$name=$names[$i];if($name -eq 'Net' -and -not $settings.ShowNetwork){continue};$d=Get-MetricData $name;$r=[System.Drawing.RectangleF]::new($content.X,$content.Y+$i*$rowH,$leftW,$rowH-5);$script:metricHitAreas[$name]=$r;$rowFill=if($selectedMetric -eq $name){Mix-Color $cardAltColor $accentColor .16}elseif($hoverButton -eq "metric:$name"){Mix-Color $cardAltColor $accentColor .10}else{$cardAltColor};$b=New-Object System.Drawing.SolidBrush($rowFill);$p=New-Object System.Drawing.Pen($(if($selectedMetric -eq $name){$accentColor}else{$gridColor}),1);Draw-RoundedRect $g $b $p $r 8;Draw-Text $g $d[0] $chipFont $mutedBrush ($r.X+8) ($r.Y+5) 40 ([System.Drawing.StringAlignment]::Near);Draw-Text $g ('{0:F0}%' -f $d[1]) $labelFont $titleBrush ($r.X+42) ($r.Y+4) 42 ([System.Drawing.StringAlignment]::Far);Draw-Bar $g ([System.Drawing.RectangleF]::new($r.X+8,$r.Bottom-10,$r.Width-16,4)) $d[1] $d[3];$p.Dispose();$b.Dispose()}
    $data=Get-MetricData $selectedMetric;$cb=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220,$cardColor));$cp=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $cb $cp $chart 12;Draw-Text $g $data[0] $chipFont $mutedBrush ($chart.X+12) ($chart.Y+10) 70 ([System.Drawing.StringAlignment]::Near);Draw-Text $g ('{0:F1}%' -f $data[1]) $metricFont $titleBrush ($chart.X+12) ($chart.Y+28) ($chart.Width-24) ([System.Drawing.StringAlignment]::Near);Draw-Text $g $data[4] $smallFont $mutedBrush ($chart.X+12) ($chart.Y+58) ($chart.Width-24) ([System.Drawing.StringAlignment]::Near);Draw-Sparkline $g $data[2] ([System.Drawing.RectangleF]::new($chart.X+12,$chart.Y+83,$chart.Width-24,$chart.Height-100)) $data[3] 100;$cp.Dispose();$cb.Dispose()
    Draw-Text $g ("UP $($target.Uptime)  |  PROC $($target.Processes)") $smallFont $mutedBrush $content.X ($content.Bottom-20) $content.Width ([System.Drawing.StringAlignment]::Near)
}
function Draw-MiniLayout($g,$content,$titleBrush,$mutedBrush){$names=@('Cpu','Memory','Disk','Net');$i=0;foreach($name in $names){if($name -eq 'Net' -and -not $settings.ShowNetwork){continue};$d=Get-MetricData $name;$y=$content.Y+$i*26;Draw-Text $g $d[0] $chipFont $mutedBrush $content.X ($y+2) 38 ([System.Drawing.StringAlignment]::Near);Draw-Bar $g ([System.Drawing.RectangleF]::new($content.X+40,$y+7,$content.Width-94,6)) $d[1] $d[3];Draw-Text $g ('{0:F0}%' -f $d[1]) $labelFont $titleBrush ($content.Right-52) $y 50 ([System.Drawing.StringAlignment]::Far);$i++}}
function Draw-StripLayout($g,$content,$titleBrush,$mutedBrush){$names=@('Cpu','Memory','Disk','Net');$count=if($settings.ShowNetwork){4}else{3};$gap=7;$w=($content.Width-$gap*($count-1))/$count;$i=0;foreach($name in $names){if($name -eq 'Net' -and -not $settings.ShowNetwork){continue};$d=Get-MetricData $name;$r=[System.Drawing.RectangleF]::new($content.X+$i*($w+$gap),$content.Y,$w,$content.Height);$b=New-Object System.Drawing.SolidBrush($cardColor);$p=New-Object System.Drawing.Pen($gridColor,1);Draw-RoundedRect $g $b $p $r 10;Draw-Text $g $d[0] $chipFont $mutedBrush ($r.X+8) ($r.Y+8) ($r.Width-16) ([System.Drawing.StringAlignment]::Near);Draw-Text $g ('{0:F0}%' -f $d[1]) $metricFont $titleBrush ($r.X+8) ($r.Y+24) ($r.Width-16) ([System.Drawing.StringAlignment]::Near);Draw-Sparkline $g $d[2] ([System.Drawing.RectangleF]::new($r.X+8,$r.Bottom-30,$r.Width-16,22)) $d[3] 100;$p.Dispose();$b.Dispose();$i++}}
function Draw-GridLayout($g,$content,$titleBrush,$mutedBrush){$gap=8;$half=($content.Width-$gap)/2;$h=($content.Height-$gap)/2;$items=@('Cpu','Memory','Disk','Net');for($i=0;$i -lt 4;$i++){$d=Get-MetricData $items[$i];$r=[System.Drawing.RectangleF]::new($content.X+($i%2)*($half+$gap),$content.Y+[Math]::Floor($i/2)*($h+$gap),$half,$h);Draw-MetricCard $g $items[$i] $d[0] $d[1] $d[4] $r $d[3]}}

function Draw-Sparkline($g,[System.Collections.Generic.List[double]]$values,[System.Drawing.RectangleF]$rect,[System.Drawing.Color]$color,[double]$maxValue) {
    if ($values.Count -lt 2 -or $rect.Width -le 1 -or $rect.Height -le 1 -or $maxValue -le 0) { return }
    $points = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i=0; $i -lt $values.Count; $i++) {
        $x = $rect.Left + ($rect.Width * $i / [Math]::Max(1,$values.Count-1))
        $v = [Math]::Min($maxValue,[Math]::Max(0,$values[$i]))
        $y = $rect.Bottom - ($rect.Height * $v / $maxValue)
        $points.Add([System.Drawing.PointF]::new($x,$y))
    }
    $area = New-Object System.Drawing.Drawing2D.GraphicsPath
    $area.AddLines($points.ToArray())
    $area.AddLine($points[$points.Count-1],[System.Drawing.PointF]::new($rect.Right,$rect.Bottom))
    $area.AddLine([System.Drawing.PointF]::new($rect.Right,$rect.Bottom),[System.Drawing.PointF]::new($rect.Left,$rect.Bottom))
    $area.CloseFigure()
    $topColor=[System.Drawing.Color]::FromArgb(68,$color)
    $bottomColor=[System.Drawing.Color]::FromArgb(4,$color)
    $gradientRect=[System.Drawing.RectangleF]::new($rect.X,$rect.Y,[Math]::Max(1,$rect.Width),[Math]::Max(1,$rect.Height))
    $areaBrush=New-Object System.Drawing.Drawing2D.LinearGradientBrush($gradientRect,$topColor,$bottomColor,90)
    $g.FillPath($areaBrush,$area)
    $areaBrush.Dispose();$area.Dispose()
    $pen = New-Object System.Drawing.Pen($color,2)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawLines($pen,$points.ToArray())
    $last=$points[$points.Count-1]
    $dotBrush=New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($dotBrush,$last.X-3,$last.Y-3,6,6)
    $dotBrush.Dispose();$pen.Dispose()
}

function Draw-Bar($g,[System.Drawing.RectangleF]$rect,[double]$value,[System.Drawing.Color]$color) {
    $baseBrush = New-Object System.Drawing.SolidBrush((Mix-Color $cardAltColor $gridColor .55))
    Draw-RoundedRect $g $baseBrush $null $rect ($rect.Height/2)
    $fillWidth = [Math]::Max($rect.Height,[Math]::Min($rect.Width,$rect.Width*$value/100))
    $fillRect = [System.Drawing.RectangleF]::new($rect.X,$rect.Y,$fillWidth,$rect.Height)
    $fillBrush = New-Object System.Drawing.SolidBrush($color)
    Draw-RoundedRect $g $fillBrush $null $fillRect ($rect.Height/2)
    $fillBrush.Dispose(); $baseBrush.Dispose()
}

function Draw-MetricCard($g,[string]$key,[string]$label,[double]$value,[string]$detail,[System.Drawing.RectangleF]$rect,[System.Drawing.Color]$color) {
    $shadowRect=[System.Drawing.RectangleF]::new($rect.X+1,$rect.Y+3,$rect.Width,$rect.Height)
    $shadowBrush=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(18,63,83,111))
    Draw-RoundedRect $g $shadowBrush $null $shadowRect 15
    $shadowBrush.Dispose()
    $cardBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238,$cardColor))
    $cardPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170,$gridColor),1)
    Draw-RoundedRect $g $cardBrush $cardPen $rect 15
    $shinePen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180,255,255,255),1)
    $g.DrawLine($shinePen,$rect.X+16,$rect.Y+1,$rect.Right-16,$rect.Y+1)
    $shinePen.Dispose()
    $labelBrush = New-Object System.Drawing.SolidBrush($mutedColor)
    $valueBrush = New-Object System.Drawing.SolidBrush($textColor)
    Draw-Text $g $label.ToUpperInvariant() $chipFont $labelBrush ($rect.X+15) ($rect.Y+13) ($rect.Width-30) ([System.Drawing.StringAlignment]::Near)
    Draw-Text $g ('{0:F1}%' -f $value) $metricFont $valueBrush ($rect.X+15) ($rect.Y+31) ($rect.Width-30) ([System.Drawing.StringAlignment]::Near)
    Draw-Text $g $detail $smallFont $labelBrush ($rect.X+15) ($rect.Y+61) ($rect.Width-30) ([System.Drawing.StringAlignment]::Near)
    Draw-Sparkline $g $histories[$key] ([System.Drawing.RectangleF]::new($rect.X+15,$rect.Y+84,$rect.Width-30,$rect.Height-105)) $color 100
    Draw-Bar $g ([System.Drawing.RectangleF]::new($rect.X+15,$rect.Bottom-13,$rect.Width-30,5)) $value $color
    $valueBrush.Dispose(); $labelBrush.Dispose(); $cardPen.Dispose(); $cardBrush.Dispose()
}

$form.Add_Paint({
    param($sender,$e)
    Get-Layout
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($background)

    if ($script:bgImage) {
        Draw-BackgroundImage $g
        $mainPen = New-Object System.Drawing.Pen((Mix-Color $gridColor $accentColor .12),1)
        Draw-RoundedRect $g $null $mainPen ([System.Drawing.RectangleF]::new(1,1,$form.ClientSize.Width-3,$form.ClientSize.Height-3)) 18
        $mainPen.Dispose()
    } else {
        $mainBrush = New-Object System.Drawing.SolidBrush($background)
        $mainPen = New-Object System.Drawing.Pen((Mix-Color $gridColor $accentColor .12),1)
        Draw-RoundedRect $g $mainBrush $mainPen ([System.Drawing.RectangleF]::new(1,1,$form.ClientSize.Width-3,$form.ClientSize.Height-3)) 18
        $mainBrush.Dispose(); $mainPen.Dispose()
    }

    $titleBrush = New-Object System.Drawing.SolidBrush($textColor)
    $mutedBrush = New-Object System.Drawing.SolidBrush($mutedColor)
    Draw-Text $g 'PERF FLOAT' $titleFont $titleBrush $layout.Header.X ($layout.Header.Y+1) 150 ([System.Drawing.StringAlignment]::Near)
    $pulseColor = if ($target.Cpu -ge $settings.CpuCrit -or $target.Memory -ge $settings.MemCrit) { Mix-Color $dangerColor $background (.25 + .25*[Math]::Sin([Environment]::TickCount/260.0)) } else { $goodColor }
    $pulseBrush = New-Object System.Drawing.SolidBrush($pulseColor)
    $g.FillEllipse($pulseBrush,$layout.Header.X+1,$layout.Header.Y+25,7,7)
    $pulseBrush.Dispose()
    $statusText = if ($script:clickThrough) { 'PASS' } else { 'LIVE' }
    Draw-Text $g ('{0}  {1:HH:mm:ss}' -f $statusText,$target.Time) $smallFont $mutedBrush ($layout.Header.X+12) ($layout.Header.Y+21) 145 ([System.Drawing.StringAlignment]::Near)
    Draw-Button $g 'layout' 'L' $layout.LayoutButton
    Draw-Button $g 'theme' 'T' $layout.Theme
    Draw-Button $g 'clickthrough' 'PT' $layout.ClickThrough
    Draw-Button $g 'compact' 'M' $layout.Compact
    Draw-Button $g 'close' 'X' $layout.Close

    $content = $layout.Content
    if($layoutMode -eq 'gamebar'){Draw-GameBarLayout $g $content $titleBrush $mutedBrush}
    elseif($layoutMode -eq 'grid'){Draw-GridLayout $g $content $titleBrush $mutedBrush}
    elseif($layoutMode -eq 'strip'){Draw-StripLayout $g $content $titleBrush $mutedBrush}
    elseif($layoutMode -eq 'mini'){Draw-MiniLayout $g $content $titleBrush $mutedBrush}
    else {
        $gap = 10
        $half = ($content.Width-$gap)/2
        $cardH = [Math]::Max(145,($content.Height-110-$gap*2)/2)
        $cpuRect=[System.Drawing.RectangleF]::new($content.X,$content.Y,$half,$cardH)
        $memRect=[System.Drawing.RectangleF]::new($content.X+$half+$gap,$content.Y,$half,$cardH)
        $diskRect=[System.Drawing.RectangleF]::new($content.X,$content.Y+$cardH+$gap,$half,$cardH)
        $netRect=[System.Drawing.RectangleF]::new($content.X+$half+$gap,$content.Y+$cardH+$gap,$half,$cardH)
        Draw-MetricCard $g 'Cpu' 'CPU' $display.Cpu ("$($target.LogicalProcessors) logical cores") $cpuRect (Threshold-Color $display.Cpu $settings.CpuWarn $settings.CpuCrit)
        Draw-MetricCard $g 'Memory' 'Memory' $display.Memory ("$(Format-Bytes $target.MemoryUsed) / $(Format-Bytes $target.MemoryTotal)") $memRect (Threshold-Color $display.Memory $settings.MemWarn $settings.MemCrit)
        Draw-MetricCard $g 'Disk' "Disk $($target.Drives)" $display.Disk ("$(Format-Bytes $target.DiskFree) free") $diskRect (Threshold-Color $display.Disk $settings.DiskWarn $settings.DiskCrit)
        if ($settings.ShowNetwork) {
            Draw-MetricCard $g 'Net' 'Network' $display.Net ("DOWN $(Format-Bytes $display.NetDown)/s  UP $(Format-Bytes $display.NetUp)/s") $netRect $cyanColor
        } else {
            Draw-MetricCard $g 'Net' 'Network' 0 'Disabled in config' $netRect $mutedColor
        }

        $footerY=$content.Y+$cardH*2+$gap*2+4
        $footerRect=[System.Drawing.RectangleF]::new($content.X,$footerY,$content.Width,[Math]::Max(74,$content.Bottom-$footerY))
        $footerBrush=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(212,$cardAltColor))
        $footerPen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(155,$gridColor),1)
        Draw-RoundedRect $g $footerBrush $footerPen $footerRect 13
        $chipGap=8; $chipW=($footerRect.Width-$chipGap*3-24)/4
        $chips=@(
            @('DISK R',"$(Format-Bytes $display.DiskRead)/s",$accentColor),
            @('DISK W',"$(Format-Bytes $display.DiskWrite)/s",$warningColor),
            @('UPTIME',$target.Uptime,$goodColor),
            @('PROCESSES',"$($target.Processes)",$cyanColor)
        )
        for($i=0;$i -lt 4;$i++){
            $x=$footerRect.X+12+$i*($chipW+$chipGap)
            $dotBrush=New-Object System.Drawing.SolidBrush([System.Drawing.Color]$chips[$i][2])
            $g.FillEllipse($dotBrush,$x,$footerRect.Y+15,6,6);$dotBrush.Dispose()
            Draw-Text $g ([string]$chips[$i][0]) $chipFont $mutedBrush ($x+10) ($footerRect.Y+10) ($chipW-10) ([System.Drawing.StringAlignment]::Near)
            Draw-Text $g ([string]$chips[$i][1]) $normalFont $titleBrush $x ($footerRect.Y+33) $chipW ([System.Drawing.StringAlignment]::Near)
        }
        Draw-Text $g ("ADAPTER  $($target.Adapter)   |   TOP MEMORY  $($target.TopProcess)") $smallFont $mutedBrush ($footerRect.X+12) ($footerRect.Bottom-22) ($footerRect.Width-24) ([System.Drawing.StringAlignment]::Near)
        $footerPen.Dispose();$footerBrush.Dispose()
    }
    if($themePanelOpen){Draw-ThemePanel $g}
    if($layoutPanelOpen){Draw-LayoutPanel $g}
    $mutedBrush.Dispose();$titleBrush.Dispose()
})

function Hit-TestButton([System.Drawing.Point]$point) {
    Get-Layout
    $x = [single]$point.X
    $y = [single]$point.Y
    if ($layout.LayoutButton.Contains($x,$y)) { return 'layout' }
    if ($layout.Close.Contains($x,$y)) { return 'close' }
    if ($layout.Compact.Contains($x,$y)) { return 'compact' }
    if ($layout.ClickThrough.Contains($x,$y)) { return 'clickthrough' }
    if ($layout.Theme.Contains($x,$y)) { return 'theme' }
    if ($script:layoutMode -eq 'gamebar' -and -not $script:layoutPanelOpen -and -not $script:themePanelOpen) {
        foreach ($name in $script:metricHitAreas.Keys) {
            if ($script:metricHitAreas[$name].Contains($x,$y)) { return ('metric:' + $name) }
        }
    }
    return ''
}

function Handle-ThemeAction([string]$action) {
    if($action.StartsWith('theme:')){Apply-Theme $action.Substring(6) $customBackground $true;return}
    if($action -eq 'custom'){
        $form.Capture=$false;$script:dragging=$false
        $dialog=New-Object System.Windows.Forms.ColorDialog;$dialog.Color=$customBackground;$dialog.FullOpen=$true
        if($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK){Apply-Theme 'custom' $dialog.Color $true}
        $dialog.Dispose();return
    }
    if($action -eq 'opacity-' -or $action -eq 'opacity+'){
        $delta=if($action -eq 'opacity+'){5}else{-5};$script:currentOpacity=[Math]::Min(100,[Math]::Max(55,$currentOpacity+$delta));$form.Opacity=$currentOpacity/100.0;Set-ConfigValue 'opacity' "$currentOpacity";return
    }
    if($action -eq 'reset'){$script:currentOpacity=90;$form.Opacity=.90;Apply-Theme 'frost' $customBackground $true;Set-ConfigValue 'opacity' '90'}
    if($action -eq 'bgimage:pick'){
        $form.Capture=$false;$script:dragging=$false
        $fd=New-Object System.Windows.Forms.OpenFileDialog
        $fd.Filter='Images (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files (*.*)|*.*'
        if($fd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK){
            if (Load-BackgroundImage $fd.FileName) {
                $settings.BackgroundImage=$fd.FileName
                Set-ConfigValue 'backgroundImage' $fd.FileName
                $form.Invalidate()
            } else {
                [System.Windows.Forms.MessageBox]::Show('The selected image could not be loaded.','PerfFloat Monitor',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        }
        $fd.Dispose();return
    }
    if($action -eq 'bgimage:clear'){$settings.BackgroundImage='';Set-ConfigValue 'backgroundImage' '';Load-BackgroundImage;$form.Invalidate();return}
    if($action -eq 'bgimage:mode'){
        $modes=@('stretch','fit','fill','tile','center')
        $i=[Array]::IndexOf($modes,[string]$settings.BackgroundImageMode)
        $settings.BackgroundImageMode=$modes[($i+1)%$modes.Count]
        Set-ConfigValue 'backgroundImageMode' $settings.BackgroundImageMode
        $form.Invalidate();return
    }
    if($action -eq 'bgopacity-' -or $action -eq 'bgopacity+'){
        $delta=if($action -eq 'bgopacity+'){5}else{-5}
        $settings.BackgroundImageOpacity=[Math]::Min(100,[Math]::Max(0,$settings.BackgroundImageOpacity+$delta))
        Set-ConfigValue 'backgroundImageOpacity' "$($settings.BackgroundImageOpacity)"
        $form.Invalidate();return
    }
}

function Set-LayoutMode([string]$mode,[bool]$persist){if($mode -notin $layoutModes){return};$script:layoutMode=$mode;$script:compact=$mode -eq 'mini';$size=$layoutSizes[$mode];$script:targetWidth=[double]$size[0];$script:targetHeight=[double]$size[1];$script:themePanelOpen=$false;$script:layoutPanelOpen=$false;if($persist){Save-State};$form.Invalidate()}
function Handle-LayoutAction([string]$action){if($action.StartsWith('layout:')){Set-LayoutMode $action.Substring(7) $true}}

function Save-State {
    if (-not $settings.RememberPosition) { return }
    $text = "version=4`r`nleft=$($form.Left)`r`ntop=$($form.Top)`r`nwidth=$($form.Width)`r`nheight=$($form.Height)`r`ncompact=$(if($layoutMode -eq 'mini'){1}else{0})`r`nlayout=$layoutMode`r`nselectedMetric=$selectedMetric`r`nsnapAnchor=$snapAnchor`r`nscreenDevice=$snapScreen`r`n"
    [System.IO.File]::WriteAllText($statePath,$text,[System.Text.UTF8Encoding]::new($false))
}

function Exit-Monitor {
    if ($exiting) { return }
    $script:exiting=$true
    Save-State
    try{[PerfFloatWin32]::UnregisterHotKey($form.Handle, $hotkeyId)}catch{}
    try{$animationTimer.Stop()}catch{}
    try{$sampleTimer.Stop()}catch{}
    try{$collector.Dispose()}catch{}
    if ($script:bgImage) { try { $script:bgImage.Dispose() } catch {}; try { if ($script:bgImageStream) { $script:bgImageStream.Dispose() } } catch {}; $script:bgImage = $null; $script:bgImageStream = $null }
    try{$tray.Visible=$false;$tray.Dispose()}catch{}
    $form.Close()
}

$form.Add_MouseDown({
    param($sender,$e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:clickThrough) { return }
    if($layoutPanelOpen){
        $panelAction=Hit-TestLayoutPanel $e.Location
        if($panelAction){$script:pressedButton=$panelAction;$form.Invalidate();return}
        $x=[single]$e.X;$y=[single]$e.Y
        if(-not $layout.LayoutPanel.Contains($x,$y) -and -not $layout.LayoutButton.Contains($x,$y)){$script:layoutPanelOpen=$false;$form.Invalidate();return}
    }
    if($themePanelOpen){
        $panelAction=Hit-TestThemePanel $e.Location
        if($panelAction){$script:pressedButton=$panelAction;$form.Invalidate();return}
        $x=[single]$e.X;$y=[single]$e.Y
        if(-not $layout.ThemePanel.Contains($x,$y) -and -not $layout.Theme.Contains($x,$y)){$script:themePanelOpen=$false;$form.Invalidate();return}
    }
    $rm = Hit-ResizeEdge $e.Location
    if ($rm) {
        $script:_resize = @{ mode=$rm; sx=$e.X; sy=$e.Y; sl=$form.Left; st=$form.Top; sw=$form.Width; sh=$form.Height }
        $script:resizeActive = $true
        $form.Capture = $true
        return
    }
    $x=[single]$e.X;$y=[single]$e.Y
    if($layoutMode -eq 'gamebar' -and -not $layoutPanelOpen -and -not $themePanelOpen){foreach($name in $metricHitAreas.Keys){if($metricHitAreas[$name].Contains($x,$y)){$script:pressedButton="metric:$name";$form.Invalidate();return}}}
    $hit=Hit-TestButton $e.Location
    if ($hit) { $script:pressedButton=$hit; $form.Invalidate(); return }
    $script:dragging=$true
    $script:dragOffset=$e.Location
    $form.Capture=$true
})
$form.Add_MouseMove({
    param($sender,$e)
    $hit=if($layoutPanelOpen){$panelHit=Hit-TestLayoutPanel $e.Location;if($panelHit){$panelHit}else{Hit-TestButton $e.Location}}elseif($themePanelOpen){$panelHit=Hit-TestThemePanel $e.Location;if($panelHit){$panelHit}else{Hit-TestButton $e.Location}}else{Hit-TestButton $e.Location}
    if ($hit -ne $hoverButton) { $script:hoverButton=$hit; $form.Invalidate() }
    if (-not $dragging -and -not $script:_resize) {
        $edge = Hit-ResizeEdge $e.Location
        if ($edge -ne $script:lastEdge) {
            $script:lastEdge = $edge
            if ($edge) { $form.Cursor = $edgeCursors[$edge] } elseif ($hit) { $form.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        }
    }
    if ($script:_resize) {
        $r = $script:_resize
        $dx = $e.X - $r.sx; $dy = $e.Y - $r.sy
        $nl = $r.sl; $nt = $r.st; $nw = $r.sw; $nh = $r.sh
        if ($r.mode -match 'e') { $nw = $r.sw + $dx }
        if ($r.mode -match 's') { $nh = $r.sh + $dy }
        if ($r.mode -match 'w') { $nw = $r.sw - $dx }
        if ($r.mode -match 'n') { $nh = $r.sh - $dy }
        $minW=$form.MinimumSize.Width; $maxW=$form.MaximumSize.Width
        $minH=$form.MinimumSize.Height; $maxH=$form.MaximumSize.Height
        $nw=[Math]::Min($maxW,[Math]::Max($minW,$nw))
        $nh=[Math]::Min($maxH,[Math]::Max($minH,$nh))
        if ($r.mode -match 'w') { $nl = ($r.sl + $r.sw) - $nw }
        if ($r.mode -match 'n') { $nt = ($r.st + $r.sh) - $nh }
        $form.SetBounds($nl, $nt, $nw, $nh)
        $script:targetWidth = $nw; $script:targetHeight = $nh
        return
    }
    if ($dragging) {
        if (([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -eq 0) {
            Finish-Drag;return
        }
        $cursor=[System.Windows.Forms.Cursor]::Position
        $rawLeft=$cursor.X-$dragOffset.X;$rawTop=$cursor.Y-$dragOffset.Y
        if($settings.ClampDuringDrag){$area=Get-WorkArea $cursor;$form.Location=Clamp-Location $rawLeft $rawTop $form.Width $form.Height $area}else{$form.Location=[System.Drawing.Point]::new($rawLeft,$rawTop)}
    }
})
$form.Add_MouseUp({
    param($sender,$e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hit=if($layoutPanelOpen){$panelHit=Hit-TestLayoutPanel $e.Location;if($panelHit){$panelHit}else{Hit-TestButton $e.Location}}elseif($themePanelOpen){$panelHit=Hit-TestThemePanel $e.Location;if($panelHit){$panelHit}else{Hit-TestButton $e.Location}}else{Hit-TestButton $e.Location}
    $action=$pressedButton
    $script:pressedButton=''
    if ($script:_resize) { Finish-Resize; return }
    if ($dragging) { Finish-Drag }
    if ($action -and $action -eq $hit) {
        if ($action -eq 'close') { Exit-Monitor; return }
        if ($action -eq 'clickthrough') { Toggle-ClickThrough; return }
        if ($action -eq 'theme') {$script:themePanelOpen=-not $themePanelOpen;$script:layoutPanelOpen=$false;if($themePanelOpen -and ($form.Width -lt 360 -or $form.Height -lt 480)){$script:targetWidth=360;$script:targetHeight=480};$form.Invalidate();return}
        if ($action -eq 'layout') {$script:layoutPanelOpen=-not $layoutPanelOpen;$script:themePanelOpen=$false;if($layoutPanelOpen -and ($form.Width -lt 330 -or $form.Height -lt 350)){$script:targetWidth=330;$script:targetHeight=350}elseif(-not $layoutPanelOpen){$size=$layoutSizes[$layoutMode];$script:targetWidth=$size[0];$script:targetHeight=$size[1]};$form.Invalidate();return}
        if ($action.StartsWith('layout:')){Handle-LayoutAction $action;$form.Invalidate();return}
        if ($action.StartsWith('metric:')){$script:selectedMetric=$action.Substring(7);Save-State;$form.Invalidate();return}
        if ($action.StartsWith('theme:') -or $action -in @('custom','opacity-','opacity+','reset','bgimage:pick','bgimage:clear','bgimage:mode','bgopacity-','bgopacity+')){Handle-ThemeAction $action;$form.Invalidate();return}
        if ($action -eq 'compact') {Set-LayoutMode 'mini' $true;return}
    }
    $form.Invalidate()
})
$form.Add_MouseLeave({ if(-not $dragging -and -not $script:_resize){$script:hoverButton='';$form.Cursor=[System.Windows.Forms.Cursors]::Default;$script:lastEdge='';$form.Invalidate()} })
$form.Add_KeyDown({ param($sender,$e) if($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape){Exit-Monitor} })
$form.Add_FormClosing({ if(-not $exiting){$_.Cancel=$true;Exit-Monitor} })

$sampleTimer=New-Object System.Windows.Forms.Timer
$sampleTimer.Interval=$settings.PollMs
$sampleTimer.Add_Tick({
    $script:target=$collector.GetSnapshot()
    if(([DateTime]::Now-$lastHistoryAt).TotalMilliseconds -ge $settings.PollMs){
        $script:lastHistoryAt=[DateTime]::Now
        foreach($item in @(@('Cpu',$target.Cpu),@('Memory',$target.Memory),@('Disk',$target.Disk),@('Net',$target.Net))){
            $list=$histories[$item[0]];$list.Add([double]$item[1]);while($list.Count -gt 42){$list.RemoveAt(0)}
        }
    }
})

$animationTimer=New-Object System.Windows.Forms.Timer
$animationTimer.Interval=50
$animationTimer.Add_Tick({
    $alpha=.16
    foreach($name in @('Cpu','Memory','Disk','Net','NetDown','NetUp','DiskRead','DiskWrite')){
        $display[$name]+=( [double]$target.$name - $display[$name])*$alpha
    }
    if(-not $dragging -and -not $script:_resize){
        $dw=$targetWidth-$form.Width;$dh=$targetHeight-$form.Height
        if([Math]::Abs($dw) -gt 1){$form.Width=[int]($form.Width+$dw*.22)}else{$form.Width=[int]$targetWidth}
        if([Math]::Abs($dh) -gt 1){$form.Height=[int]($form.Height+$dh*.22)}else{$form.Height=[int]$targetHeight}
        Ensure-OnScreen ([bool]$snapAnchor)
    }
    $form.Invalidate()
})

$tray=New-Object System.Windows.Forms.NotifyIcon
$tray.Text='PerfFloat Monitor'
$tray.Icon=[System.Drawing.SystemIcons]::Information
$tray.Visible=$true
$menu=New-Object System.Windows.Forms.ContextMenuStrip
$showItem=$menu.Items.Add('Show / Hide')
$compactItem=$menu.Items.Add('Mini layout')
$configItem=$menu.Items.Add('Edit config')
$script:mClick=$menu.Items.Add('穿透模式 Click-through')
$script:mClick.Checked=$script:clickThrough
[void]$menu.Items.Add('-')
$exitItem=$menu.Items.Add('Exit')
$showItem.Add_Click({$form.Visible=-not $form.Visible;if($form.Visible){$form.Activate()}})
$compactItem.Add_Click({Set-LayoutMode 'mini' $true})
$configItem.Add_Click({Start-Process -FilePath 'notepad.exe' -ArgumentList $configPath})
$script:mClick.Add_Click({Toggle-ClickThrough})
$exitItem.Add_Click({Exit-Monitor})
$tray.ContextMenuStrip=$menu
$tray.Add_MouseClick({param($sender,$e)if($e.Button -eq [System.Windows.Forms.MouseButtons]::Left){$form.Visible=-not $form.Visible;if($form.Visible){$form.Activate()}}})

if ($compact) { $form.Height=$compactHeight }
Ensure-OnScreen ([bool]$snapAnchor)

# 全局热键（Ctrl+Alt+P 切换穿透）+ 穿透样式兜底 + 背景图加载
$form.Add_HotKeyPressed({ param($id) if ($id -eq $hotkeyId) { Toggle-ClickThrough } })
if ($form.GetType().Name -eq 'HotKeyForm') { $form.Add_PassThroughButtonClicked({ Toggle-ClickThrough }) }
$form.Add_HandleCreated({ if ($script:clickThrough) { Set-ClickThrough } })
[void]$form.Handle
try { [PerfFloatWin32]::RegisterHotKey($form.Handle, $hotkeyId, (0x1 -bor 0x2 -bor 0x4000), 0x50) | Out-Null } catch { }
if ($script:clickThrough) { Set-ClickThrough }
Load-BackgroundImage

$sampleTimer.Start();$animationTimer.Start()
[System.Windows.Forms.Application]::Run($form)

try{$collector.Dispose()}catch{}
try{$mutex.ReleaseMutex()}catch{}
$mutex.Dispose()
