# ============================================================
#  PC Health Check - Diagnose Slowness
#  Run: powershell -ExecutionPolicy Bypass -File pc_health_check.ps1
# ============================================================

$sep = "=" * 55

function Section($title) {
    Write-Host ""
    Write-Host $sep -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Yellow
    Write-Host $sep -ForegroundColor Cyan
}

function OK($msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function WARN($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function BAD($msg)  { Write-Host "  [XX]  $msg" -ForegroundColor Red }

# 1. RAM
Section "RAM Usage"
$os = Get-CimInstance Win32_OperatingSystem
$totalGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeGB   = [math]::Round($os.FreePhysicalMemory     / 1MB, 1)
$usedGB   = [math]::Round($totalGB - $freeGB, 1)
$usedPct  = [math]::Round(($usedGB / $totalGB) * 100)
Write-Host "  Total: ${totalGB} GB   Used: ${usedGB} GB   Free: ${freeGB} GB   ($usedPct%)"
if     ($usedPct -ge 90) { BAD  "RAM critically full - heavy paging to disk expected" }
elseif ($usedPct -ge 75) { WARN "RAM at $usedPct% - paging may be slowing you down" }
else                     { OK   "RAM usage looks fine" }

# 2. Top RAM hogs
Section "Top 5 Memory Hogs"
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
    ForEach-Object {
        $mb = [math]::Round($_.WorkingSet64 / 1MB)
        Write-Host ("  {0,-30} {1,6} MB" -f $_.ProcessName, $mb)
    }

# 3. CPU
Section "CPU Usage (5-second average)"
$samples = 1..5 | ForEach-Object { (Get-CimInstance Win32_Processor).LoadPercentage; Start-Sleep 1 }
$avgCPU  = [math]::Round(($samples | Measure-Object -Average).Average)
Write-Host "  Average CPU load: $avgCPU%"
if     ($avgCPU -ge 85) { BAD  "CPU maxed out" }
elseif ($avgCPU -ge 60) { WARN "CPU moderately loaded" }
else                    { OK   "CPU load is normal" }

# 4. Top CPU hogs
Section "Top 5 CPU Hogs"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 |
    ForEach-Object {
        $cpu = [math]::Round($_.CPU, 1)
        Write-Host ("  {0,-30} {1,8}s CPU time" -f $_.ProcessName, $cpu)
    }

# 5. Disk space
Section "Disk Space"
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } |
    ForEach-Object {
        $totalDisk = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
        $freeDisk  = [math]::Round($_.Free / 1GB, 1)
        $pctFree   = if ($totalDisk -gt 0) { [math]::Round(($freeDisk / $totalDisk) * 100) } else { 0 }
        Write-Host ("  Drive {0}:  {1} GB free of {2} GB  ({3}% free)" -f $_.Name, $freeDisk, $totalDisk, $pctFree)
        if     ($pctFree -le 5)  { BAD  "Drive $($_.Name): critically low - virtual memory will fail" }
        elseif ($pctFree -le 15) { WARN "Drive $($_.Name): low - paging performance impacted" }
        else                     { OK   "Drive $($_.Name): space OK" }
    }

# 6. Disk I/O
Section "Disk I/O Activity"
try {
    $diskRead  = (Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec'  -SampleInterval 1 -MaxSamples 3).CounterSamples.CookedValue | Measure-Object -Average | Select-Object -ExpandProperty Average
    $diskWrite = (Get-Counter '\PhysicalDisk(_Total)\Disk Write Bytes/sec' -SampleInterval 1 -MaxSamples 3).CounterSamples.CookedValue | Measure-Object -Average | Select-Object -ExpandProperty Average
    $readMB    = [math]::Round($diskRead  / 1MB, 2)
    $writeMB   = [math]::Round($diskWrite / 1MB, 2)
    Write-Host "  Read:  $readMB MB/s    Write: $writeMB MB/s"
    if (($readMB + $writeMB) -gt 100) { WARN "High disk I/O - may indicate heavy paging or indexing" }
    else                               { OK   "Disk I/O normal" }
} catch {
    Write-Host "  Could not read disk counters - run as Administrator" -ForegroundColor DarkGray
}

# 7. Disk type
Section "Disk Type Detection"
try {
    Get-PhysicalDisk | ForEach-Object {
        $type = $_.MediaType
        $name = $_.FriendlyName
        Write-Host "  $name  ->  $type"
        if ($type -eq "HDD") { WARN "HDD detected - much slower than SSD" }
        elseif ($type -eq "SSD") { OK "SSD detected - good" }
        else { Write-Host "  Type undetected - may be NVMe or virtual disk" -ForegroundColor DarkGray }
    }
} catch {
    Write-Host "  Run as Administrator to detect disk type" -ForegroundColor DarkGray
}

# 8. Temperature
Section "CPU Temperature"
try {
    $temps = Get-CimInstance -Namespace "root/OpenHardwareMonitor" -ClassName Sensor |
             Where-Object { $_.SensorType -eq "Temperature" -and $_.Name -like "*CPU*" }
    if ($temps) {
        $temps | ForEach-Object { Write-Host ("  {0,-35} {1} C" -f $_.Name, [math]::Round($_.Value)) }
        $maxTemp = ($temps | Measure-Object -Property Value -Maximum).Maximum
        if     ($maxTemp -ge 90) { BAD  "CPU overheating - throttling very likely!" }
        elseif ($maxTemp -ge 80) { WARN "CPU running hot - check thermal paste and fans" }
        else                     { OK   "Temperature normal" }
    } else {
        Write-Host "  No sensor data. Install OpenHardwareMonitor + enable WMI to see temps." -ForegroundColor DarkGray
        Write-Host "  https://openhardwaremonitor.org" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  Temperature check skipped (OpenHardwareMonitor not running)" -ForegroundColor DarkGray
}

# 9. Startup programs
Section "Startup Programs"
$startupPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)
$startupItems = @()
foreach ($path in $startupPaths) {
    if (Test-Path $path) {
        $props = Get-ItemProperty $path
        $props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
            $startupItems += $_.Name
            Write-Host "  $($_.Name)"
        }
    }
}
if     ($startupItems.Count -gt 10) { WARN "$($startupItems.Count) startup items - many apps auto-launch at boot" }
elseif ($startupItems.Count -gt 0)  { OK   "$($startupItems.Count) startup items found" }
else                                 { OK   "No startup items found" }

# 10. Page file
Section "Virtual Memory / Page File"
Get-CimInstance Win32_PageFileUsage | ForEach-Object {
    $allocMB = $_.AllocatedBaseSize
    $usedMB  = $_.CurrentUsage
    $pct     = if ($allocMB -gt 0) { [math]::Round(($usedMB / $allocMB) * 100) } else { 0 }
    Write-Host ("  {0}   Allocated: {1} MB   Used: {2} MB   ({3}%)" -f $_.Name, $allocMB, $usedMB, $pct)
    if     ($pct -ge 80) { BAD  "Page file heavily used - add more RAM or free disk space" }
    elseif ($pct -ge 40) { WARN "Page file in use - your PC is paging to disk" }
    else                 { OK   "Page file usage low" }
}

# Summary
Write-Host ""
Write-Host $sep -ForegroundColor Cyan
Write-Host "  Done! Review any [!!] WARN or [XX] BAD items above." -ForegroundColor Yellow
Write-Host $sep -ForegroundColor Cyan
Write-Host ""
