param(
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(10, 1800)][int]$Seconds = 60,
    [ValidateRange(1, 30)][int]$Interval = 5
)
$ErrorActionPreference = 'Stop'
# Read-only process counters; does not start/stop the app, change priority or UI.
$processes = @(Get-Process SwiftyToys -ErrorAction Stop)
$tracked = foreach ($process in $processes) {
    [pscustomobject]@{ Id = $process.Id; Started = $process.StartTime; Cpu = $process.TotalProcessorTime.TotalSeconds }
}
$timer = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
    foreach ($item in $tracked) {
        $process = Get-Process -Id $item.Id -ErrorAction Stop
        if ($process.StartTime -ne $item.Started) { throw 'Process changed during measurement.' }
        $samples += [pscustomobject]@{
            elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            pid = $process.Id
            cpuSeconds = $process.TotalProcessorTime.TotalSeconds - $item.Cpu
            privateBytes = $process.PrivateMemorySize64
            workingSetBytes = $process.WorkingSet64
            handles = $process.HandleCount
            threads = $process.Threads.Count
        }
    }
    Start-Sleep -Seconds $Interval
}
$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$executables = foreach ($process in $processes) {
    [pscustomobject]@{ pid = $process.Id; path = $process.Path; size = (Get-Item -LiteralPath $process.Path).Length; sha256 = (Get-FileHash -LiteralPath $process.Path -Algorithm SHA256).Hash }
}
$result = [ordered]@{
    recorded = (Get-Date).ToString('o')
    scope = 'Short idle process-counter sample; no startup/input latency/low-end hardware claim.'
    seconds = $timer.Elapsed.TotalSeconds
    windows = $os.Caption
    build = $os.BuildNumber
    model = $computer.Model
    logicalProcessors = $computer.NumberOfLogicalProcessors
    physicalMemoryBytes = $computer.TotalPhysicalMemory
    powerPlan = (& powercfg /getactivescheme | Out-String).Trim()
    executables = @($executables)
    samples = $samples
}
$absolute = [IO.Path]::GetFullPath($OutputPath)
[IO.File]::WriteAllText($absolute, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
foreach ($item in $tracked) {
    $last = $samples | Where-Object pid -eq $item.Id | Select-Object -Last 1
    [pscustomobject]@{ Pid = $item.Id; OneCoreCpuPercent = [Math]::Round(100 * $last.cpuSeconds / $last.elapsedSeconds, 3); PrivateMiB = [Math]::Round($last.privateBytes / 1MB, 2); WorkingSetMiB = [Math]::Round($last.workingSetBytes / 1MB, 2); Threads = $last.threads; Handles = $last.handles }
}
