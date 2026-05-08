[CmdletBinding()]
param(
    [string]$BasePath = "C:\servers",
    [string]$InstanceName,
    [ValidateSet("Foreground", "Background")][string]$RunMode
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

    if ($PSBoundParameters.ContainsKey("RunMode")) {
        $quotedRunMode = '"{0}"' -f $RunMode
        $argumentList = "$argumentList -RunMode $quotedRunMode"
    }

    Write-Host "> Restarting start_server.ps1 with administrative privileges..."
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -Verb RunAs | Out-Null
    return
}

if (-not $PSBoundParameters.ContainsKey("BasePath")) {
    $BasePath = Read-Host "Base path (default: C:\servers)"
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = "C:\servers"
    }
}

function Resolve-InstanceName {
    param(
        [string]$ProvidedInstanceName
    )

    if ($ProvidedInstanceName) {
        return $ProvidedInstanceName
    }

    while ($true) {
        $input = [string](Read-Host "Instance name (mandatory)")
        if (-not [string]::IsNullOrWhiteSpace($input)) {
            return $input.Trim()
        }
        Write-Warning "Instance name cannot be empty."
    }
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

function Resolve-RunMode {
    param(
        [string]$SelectedRunMode
    )

    if ($SelectedRunMode) {
        return $SelectedRunMode
    }

    while ($true) {
        $choice = [string](Read-Host "Run mode for '$InstanceName' ([F]oreground/[B]ackground)")

        switch -Regex ($choice.Trim()) {
            '^(?i:f|foreground)$' { return "Foreground" }
            '^(?i:b|background)$' { return "Background" }
            default { Write-Warning "Enter F/Foreground or B/Background." }
        }
    }
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

$InstanceName = Resolve-InstanceName -ProvidedInstanceName $InstanceName
$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$startupTaskName = "ConanStartOnBoot-$instanceKey"

$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$serverExe = Resolve-ServerExecutablePath -InstallPath $gameFilesPath
$resolvedRunMode = Resolve-RunMode -SelectedRunMode $RunMode
$existingProcesses = @(Get-InstanceProcesses -InstallPath $gameFilesPath)

if ($existingProcesses.Count -gt 0) {
    $processIds = ($existingProcesses | ForEach-Object { $_.ProcessId }) -join ", "
    Write-Warning "Instance '$InstanceName' is already running (PID: $processIds)."
    return
}

Write-Host "Starting instance '$InstanceName' in $resolvedRunMode mode..."

if ($resolvedRunMode -eq "Foreground") {
    Write-Warning "Foreground mode is not available when using scheduled-task start. Using background scheduled task instead."
}

$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
if (-not $startupTask) {
    throw "Scheduled start task '$startupTaskName' was not found. Run set_task.ps1 for this instance first."
}

Write-Host "Triggering scheduled start task '$startupTaskName' for instance '$InstanceName'..."
Start-ScheduledTask -TaskName $startupTaskName

$maxWaitSeconds = 60
$elapsed = 0
while ($elapsed -lt $maxWaitSeconds) {
    $runningProcesses = @(Get-InstanceProcesses -InstallPath $gameFilesPath)
    if ($runningProcesses.Count -gt 0) {
        $processIds = ($runningProcesses | ForEach-Object { $_.ProcessId }) -join ", "
        Write-Host "Instance '$InstanceName' started via scheduled task '$startupTaskName' (PID: $processIds)."
        return
    }

    Start-Sleep -Seconds 2
    $elapsed += 2
}

throw "Scheduled start task '$startupTaskName' ran, but instance '$InstanceName' did not start within $maxWaitSeconds seconds."