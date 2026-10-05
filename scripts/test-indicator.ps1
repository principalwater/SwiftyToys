param([string]$Executable = (Join-Path $env:LOCALAPPDATA 'SwiftyToys\SwiftyToys.exe'))
# Interactive regression check: briefly pauses only SwiftyToys's tray thread.
# No hardware brightness is changed; the original indicator setting is restored.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BrightnessIndicatorCheck {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string type, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, UIntPtr value, IntPtr data);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowBand(IntPtr window, out uint band);
    [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr window, IntPtr region);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr window, IntPtr region, bool redraw);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr region);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] public static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr value, IntPtr data, uint flags, uint timeout, out UIntPtr result);
    public struct Rect { public int Left, Top, Right, Bottom; }
    private static void RefreshOSD(IntPtr control) {
        UIntPtr result;
        if (SendMessageTimeout(control, 0x8001, new UIntPtr(2), IntPtr.Zero, 3, 16000, out result) == IntPtr.Zero || result == UIntPtr.Zero)
            throw new InvalidOperationException("Could not refresh the OSD without changing brightness.");
    }
    public static int CheckOSDPosition(IntPtr control, IntPtr osd) {
        RefreshOSD(control);
        Rect expected;
        if (!GetWindowRect(osd, out expected)) throw new InvalidOperationException("Could not inspect the OSD.");
        Exception error = null;
        var worker = new System.Threading.Thread(() => {
            try { for (int i = 0; i < 40; i++) { RefreshOSD(control); System.Threading.Thread.Sleep(15); } }
            catch (Exception failure) { error = failure; }
        });
        int samples = 0;
        worker.Start();
        try {
            while (worker.IsAlive) {
                Rect actual;
                if (IsWindowVisible(osd)) {
                    if (!GetWindowRect(osd, out actual) || !actual.Equals(expected))
                        throw new InvalidOperationException("The visible OSD moved during repeated updates.");
                    samples++;
                }
                System.Threading.Thread.Sleep(1);
            }
        } finally { worker.Join(); }
        if (error != null) throw error;
        return samples;
    }
}
'@
function Invoke-BrightnessCLI([string[]]$CLIArguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = $CLIArguments -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(25000)) { throw 'SwiftyToys CLI timed out.' }
        $output = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0) { throw ('SwiftyToys CLI failed: ' + $process.StandardError.ReadToEnd()) }
        return $output
    } finally { $process.Dispose() }
}
function Assert-Indicator([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$control = [BrightnessIndicatorCheck]::FindWindow('SwiftyToys.Control', 'SwiftyToys.Software.v2')
$observer = [BrightnessIndicatorCheck]::FindWindow('STATIC', 'SwiftyToys.Indicator')
$osd = [BrightnessIndicatorCheck]::FindWindow('SwiftyToys.OSD', 'SwiftyToys')
$native = [BrightnessIndicatorCheck]::FindWindow('NativeHWNDHost', '')
if ($native -eq [IntPtr]::Zero) { $native = [BrightnessIndicatorCheck]::FindWindow('XamlExplorerHostIslandWindow', '') }
Assert-Indicator ($control -ne [IntPtr]::Zero -and $observer -ne [IntPtr]::Zero) 'Run SwiftyToys 0.5.3 or later first.'
Assert-Indicator ($native -ne [IntPtr]::Zero) 'Press a native brightness/volume key once to create the Windows flyout, then retry.'
[uint32]$nativePID = 0; [uint32]$shellPID = 0; [uint32]$band = 0
[void][BrightnessIndicatorCheck]::GetWindowThreadProcessId($native, [ref]$nativePID)
[void][BrightnessIndicatorCheck]::GetWindowThreadProcessId([BrightnessIndicatorCheck]::GetShellWindow(), [ref]$shellPID)
Assert-Indicator ($nativePID -eq $shellPID -and [BrightnessIndicatorCheck]::GetWindowBand($native, [ref]$band) -and $band -eq 18) 'Native flyout does not match the recognized Shell signature.'
$originalMode = Invoke-BrightnessCLI @('osd')
$originalLevel = Invoke-BrightnessCLI @('get')
$originalVisibility = [BrightnessIndicatorCheck]::IsWindowVisible($native)
$shellMessage = [BrightnessIndicatorCheck]::RegisterWindowMessage('SHELLHOOK')
function Send-IndicatorTrigger([uint32]$Code) {
    Assert-Indicator ([BrightnessIndicatorCheck]::PostMessage($observer, $shellMessage, [UIntPtr]::new($Code), [IntPtr]::Zero)) 'Could not post a Shell trigger.'
    Start-Sleep -Milliseconds 30
}
function Show-NativeIndicator {
    [void][BrightnessIndicatorCheck]::ShowWindowAsync($native, 8)
    Start-Sleep -Milliseconds 80
}
function Hide-NativeIndicator {
    [void][BrightnessIndicatorCheck]::ShowWindowAsync($native, 0)
    Start-Sleep -Milliseconds 30
}
function Get-NativeRegion {
    $region = [BrightnessIndicatorCheck]::CreateRectRgn(0, 0, 0, 0)
    Assert-Indicator ($region -ne [IntPtr]::Zero) 'Could not inspect the native window region.'
    try { return [BrightnessIndicatorCheck]::GetWindowRgn($native, $region) }
    finally { [void][BrightnessIndicatorCheck]::DeleteObject($region) }
}
try {
    [void](Invoke-BrightnessCLI @('osd', 'custom'))
    Start-Sleep -Milliseconds 30
    Assert-Indicator ((Get-NativeRegion) -eq 1) 'Native window was not pre-clipped before the first show.'
    Assert-Indicator ([BrightnessIndicatorCheck]::SetWindowRgn($native, [IntPtr]::Zero, $true) -ne 0) 'Could not simulate a native layout reset.'
    Send-IndicatorTrigger 55
    Assert-Indicator ((Get-NativeRegion) -eq 1) 'A native layout reset permanently removed pre-show clipping.'
    Assert-Indicator ($osd -ne [IntPtr]::Zero) 'The custom OSD window is unavailable.'
    $positionSamples = [BrightnessIndicatorCheck]::CheckOSDPosition($control, $osd)
    Assert-Indicator ($positionSamples -gt 0) 'No visible OSD position samples were collected.'
    Send-IndicatorTrigger 55
    Start-Sleep -Milliseconds 650
    Show-NativeIndicator
    Assert-Indicator (-not [BrightnessIndicatorCheck]::IsWindowVisible($native)) 'Delayed brightness show escaped suppression.'
    Hide-NativeIndicator
    [uint32]$controlPID = 0
    $threadID = [BrightnessIndicatorCheck]::GetWindowThreadProcessId($control, [ref]$controlPID)
    $thread = [BrightnessIndicatorCheck]::OpenThread(2, $false, $threadID)
    Assert-Indicator ($thread -ne [IntPtr]::Zero) 'Could not open the tray thread.'
    $suspended = $false
    try {
        $suspended = [BrightnessIndicatorCheck]::SuspendThread($thread) -ne [uint32]::MaxValue
        Assert-Indicator $suspended 'Could not pause the tray thread.'
        Send-IndicatorTrigger 55
        Show-NativeIndicator
        Assert-Indicator (-not [BrightnessIndicatorCheck]::IsWindowVisible($native)) 'Brightness flyout appeared while the tray UI was blocked.'
    } finally {
        if ($suspended) { [void][BrightnessIndicatorCheck]::ResumeThread($thread) }
        [void][BrightnessIndicatorCheck]::CloseHandle($thread)
    }
    Hide-NativeIndicator
    foreach ($mediaCode in @(12, 56)) {
        Send-IndicatorTrigger 55
        Send-IndicatorTrigger $mediaCode
        Assert-Indicator ((Get-NativeRegion) -eq 0) 'A media trigger did not restore the original window region.'
        Show-NativeIndicator
        # The Shell can close a synthetic show with an existing animation timer.
        # The restored region above checks our cancellation independently of it.
        Hide-NativeIndicator
    }
    [void](Invoke-BrightnessCLI @('osd', 'system'))
    Send-IndicatorTrigger 55
    Assert-Indicator ((Get-NativeRegion) -eq 0) 'System mode did not restore the original window region.'
    Show-NativeIndicator
    Assert-Indicator ((Get-NativeRegion) -eq 0) 'System indicator mode changed the Windows window region.'
    Assert-Indicator ((Invoke-BrightnessCLI @('get')) -eq $originalLevel) 'The indicator check changed brightness.'
    Write-Host "PASS: pre-show clipping, delayed shows, blocked UI, media restoration, system mode and stable OSD ($positionSamples samples); unchanged brightness."
} finally {
    [void][BrightnessIndicatorCheck]::ShowWindowAsync($native, $(if ($originalVisibility) { 8 } else { 0 }))
    [void](Invoke-BrightnessCLI @('osd', $originalMode))
}
