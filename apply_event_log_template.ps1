[CmdletBinding()]
param(
    [string]$BasePath = "C:\servers",
    [Parameter(Mandatory)][string]$InstanceName
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path

    if (-not $scriptPath) {
        throw "Cannot self-elevate because the script path is unavailable."
    }

    $quotedScriptPath = '"{0}"' -f $scriptPath
    $quotedBasePath = '"{0}"' -f $BasePath
    $quotedInstanceName = '"{0}"' -f $InstanceName
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -BasePath $quotedBasePath -InstanceName $quotedInstanceName"

    Write-Host "> Restarting apply_event_log_template.ps1 with administrative privileges..."
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -Verb RunAs | Out-Null
    return
}

function Get-ServerExecutableCandidates {
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    return @(
        (Join-Path $InstallPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Shipping.exe"),
        (Join-Path $InstallPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Test.exe"),
        (Join-Path $InstallPath "ConanSandboxServer.exe")
    )
}

function Resolve-ServerExecutablePath {
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    foreach ($candidate in Get-ServerExecutableCandidates -InstallPath $InstallPath) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "Server executable not found under: $InstallPath"
}

function Get-InstanceProcesses {
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    $candidatePaths = Get-ServerExecutableCandidates -InstallPath $InstallPath |
        Where-Object { Test-Path $_ } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) }

    return Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @(
                "ConanSandboxServer.exe",
                "ConanSandboxServer-Win64-Shipping.exe",
                "ConanSandboxServer-Win64-Test.exe"
            ) -and (
                ($_.ExecutablePath -and ($candidatePaths -contains [System.IO.Path]::GetFullPath($_.ExecutablePath))) -or
                ($_.CommandLine -and $_.CommandLine.IndexOf($InstallPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            )
        }
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $currentSection = $null
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $currentSection = $matches[1]
            continue
        }

        if ($currentSection -ieq $Section -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$')) {
            return $matches[1]
        }
    }

    return $null
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) {
        foreach ($line in @(Get-Content -Path $Path)) {
            $lines.Add([string]$line)
        }
    }

    $sectionHeader = "[$Section]"
    $sectionStart = -1
    $sectionEnd = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
            if ($matches[1] -ieq $Section) {
                $sectionStart = $i
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j] -match '^\s*\[(.+)\]\s*$') {
                        $sectionEnd = $j
                        break
                    }
                }
                break
            }
        }
    }

    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add("")
        }
        $lines.Add($sectionHeader)
        $lines.Add("$Key=$Value")
        Set-Content -Path $Path -Value $lines -Encoding UTF8
        return
    }

    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=.*$')) {
            $lines[$i] = "$Key=$Value"
            Set-Content -Path $Path -Value $lines -Encoding UTF8
            return
        }
    }

    $lines.Insert($sectionEnd, "$Key=$Value")
    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

function Stop-InstanceForConfigEdit {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string]$StartupTaskName
    )

    $startupTask = Get-ScheduledTask -TaskName $StartupTaskName -ErrorAction SilentlyContinue
    if ($startupTask -and $startupTask.State -eq "Running") {
        Stop-ScheduledTask -TaskName $StartupTaskName -ErrorAction SilentlyContinue
    }

    Get-InstanceProcesses -InstallPath $InstallPath | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $maxWaitSeconds = 60
    $elapsed = 0
    while ($elapsed -lt $maxWaitSeconds) {
        if (@(Get-InstanceProcesses -InstallPath $InstallPath).Count -eq 0) {
            return
        }

        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    throw "Instance '$InstanceName' is still running after $maxWaitSeconds seconds."
}

function Start-InstanceAfterConfigEdit {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string]$StartupTaskName
    )

    $startupTask = Get-ScheduledTask -TaskName $StartupTaskName -ErrorAction SilentlyContinue
    if ($startupTask) {
        Start-ScheduledTask -TaskName $StartupTaskName
    }
    else {
        $serverExe = Resolve-ServerExecutablePath -InstallPath $InstallPath
        $workingDirectory = Split-Path -Parent $serverExe
        Start-Process -FilePath $serverExe -ArgumentList "-log" -WorkingDirectory $workingDirectory | Out-Null
    }

    $maxWaitSeconds = 60
    $elapsed = 0
    while ($elapsed -lt $maxWaitSeconds) {
        $runningProcesses = @(Get-InstanceProcesses -InstallPath $InstallPath)
        if ($runningProcesses.Count -gt 0) {
            return $runningProcesses
        }

        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    throw "Instance '$InstanceName' did not start within $maxWaitSeconds seconds after applying the server-settings template."
}

$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$configRoot = Join-Path $gameFilesPath "ConanSandbox\Saved\Config\WindowsServer"
$serverSettingsPath = Join-Path $configRoot "ServerSettings.ini"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultConfigRoot = Join-Path $scriptRoot "defaults\ConanSandbox\Saved\Config\WindowsServer"
$defaultServerSettingsPath = Join-Path $defaultConfigRoot "ServerSettings.ini"
$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$startupTaskName = "ConanStartOnBoot-$instanceKey"
$templateKeys = @(
    "ShowOnlinePlayers",
    "EventLogCauserPrivacy",
    "EventLogPvECauserPrivacy",
    "EventLogPvPCauserPrivacy",
    "RestrictPVPBuildingDamageTime",
    "CanDamagePlayerOwnedStructures",
    "PVPBuildingDamageTimeMondayStart",
    "PVPBuildingDamageTimeTuesdayStart",
    "PVPBuildingDamageTimeWednesdayStart",
    "PVPBuildingDamageTimeThursdayStart",
    "PVPBuildingDamageTimeFridayStart",
    "PVPBuildingDamageTimeSaturdayStart",
    "PVPBuildingDamageTimeSundayStart",
    "PVPBuildingDamageTimeMondayEnd",
    "PVPBuildingDamageTimeTuesdayEnd",
    "PVPBuildingDamageTimeWednesdayEnd",
    "PVPBuildingDamageTimeThursdayEnd",
    "PVPBuildingDamageTimeFridayEnd",
    "PVPBuildingDamageTimeSaturdayEnd",
    "PVPBuildingDamageTimeSundayEnd",
    "PVPBuildingDamageEnabledMonday",
    "PVPBuildingDamageEnabledTuesday",
    "PVPBuildingDamageEnabledWednesday",
    "PVPBuildingDamageEnabledThursday",
    "PVPBuildingDamageEnabledFriday",
    "PVPBuildingDamageEnabledSaturday",
    "PVPBuildingDamageEnabledSunday"
)

if (-not (Test-Path $serverSettingsPath)) {
    throw "ServerSettings.ini was not found for instance '$InstanceName': $serverSettingsPath"
}

if (-not (Test-Path $defaultServerSettingsPath)) {
    throw "Template ServerSettings.ini was not found: $defaultServerSettingsPath"
}

$desiredValues = @{}
foreach ($key in $templateKeys) {
    $value = [string](Get-IniValue -Path $defaultServerSettingsPath -Section "ServerSettings" -Key $key)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Template setting '$key' was not found in $defaultServerSettingsPath"
    }

    $desiredValues[$key] = $value
}

$previousValues = @{}
foreach ($key in $templateKeys) {
    $previousValues[$key] = [string](Get-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key $key)
}

$backupDate = Get-Date
$backupFolder = Join-Path $serverRoot (Join-Path (Join-Path "config_backups" ($backupDate.ToString("yyyy\\MM\\dd"))) ("server-settings-" + $backupDate.ToString("yyyyMMdd-HHmmss")))
$instanceWasRunning = @(Get-InstanceProcesses -InstallPath $gameFilesPath).Count -gt 0

if ($instanceWasRunning) {
    Write-Host "> Stopping instance '$InstanceName' before editing ServerSettings.ini..."
    Stop-InstanceForConfigEdit -InstallPath $gameFilesPath -StartupTaskName $startupTaskName
}
else {
    Write-Host "> Instance '$InstanceName' is not currently running. Applying template and then starting it."
}

New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
Copy-Item -Path $serverSettingsPath -Destination (Join-Path $backupFolder "ServerSettings.ini") -Force
Write-Host "> Backed up current ServerSettings.ini to $backupFolder"

foreach ($key in $templateKeys) {
    Set-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key $key -Value $desiredValues[$key]
}

$verificationFailures = New-Object System.Collections.Generic.List[string]
foreach ($key in $templateKeys) {
    $actualValue = [string](Get-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key $key)
    if ($actualValue -ne $desiredValues[$key]) {
        $verificationFailures.Add("$key=$actualValue (expected $($desiredValues[$key]))")
    }
}

if ($verificationFailures.Count -gt 0) {
    throw "Failed to apply one or more template settings: $($verificationFailures -join '; ')"
}

Write-Host "> Applied event-log/privacy/building-damage template values from $defaultServerSettingsPath"
foreach ($key in $templateKeys) {
    Write-Host ("- {0}: {1} -> {2}" -f $key, $previousValues[$key], $desiredValues[$key])
}

Write-Host "> Starting instance '$InstanceName' so the updated config is live..."
$runningProcesses = @(Start-InstanceAfterConfigEdit -InstallPath $gameFilesPath -StartupTaskName $startupTaskName)
$processIds = ($runningProcesses | ForEach-Object { $_.ProcessId }) -join ", "

Write-Host "> Server settings template apply complete."
Write-Host "> Backup folder: $backupFolder"
Write-Host "> Running PID(s): $processIds"