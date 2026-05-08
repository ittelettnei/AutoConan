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

    Write-Host "> Restarting stop_server.ps1 with administrative privileges..."
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

$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$startupTaskName = "ConanStartOnBoot-$instanceKey"

$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
if (-not $startupTask) {
    throw "Scheduled start task '$startupTaskName' was not found. Run set_task.ps1 for this instance first."
}

Write-Host "Ending scheduled start task '$startupTaskName' for instance '$InstanceName'..."

if ($startupTask.State -eq "Running") {
    Stop-ScheduledTask -TaskName $startupTaskName -ErrorAction Stop
}

Get-InstanceProcesses -InstallPath $gameFilesPath | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

$maxWaitSeconds = 60
$elapsed = 0
while ($elapsed -lt $maxWaitSeconds) {
    $remaining = @(Get-InstanceProcesses -InstallPath $gameFilesPath).Count
    if ($remaining -eq 0) {
        Write-Host "Instance '$InstanceName' stopped by ending task '$startupTaskName'."
        return
    }

    Start-Sleep -Seconds 2
    $elapsed += 2
}

throw "Task '$startupTaskName' was ended, but instance '$InstanceName' is still running after $maxWaitSeconds seconds."