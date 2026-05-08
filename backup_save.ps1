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

    Write-Host "> Restarting backup_save.ps1 with administrative privileges..."
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

$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$savedPath = Join-Path $gameFilesPath "ConanSandbox\Saved"
$serverExe = Resolve-ServerExecutablePath -InstallPath $gameFilesPath

if (-not (Test-Path $savedPath)) {
    throw "Saved path not found for instance '$InstanceName': $savedPath"
}

$isRunning = @(Get-InstanceProcesses -InstallPath $gameFilesPath).Count -gt 0
if ($isRunning) {
    throw "Refusing to create a backup while instance '$InstanceName' is running."
}

$backupDate = Get-Date
$backupRoot = Join-Path $serverRoot (Join-Path "backups" ($backupDate.ToString("yyyy\\MM\\dd")))
$archiveFileName = '{0}-{1:yyyy.MM.dd_HH.mm.ss}_backup.zip' -f $InstanceName, $backupDate
$archivePath = Join-Path $backupRoot $archiveFileName

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

if (Test-Path $archivePath) {
    Remove-Item -Path $archivePath -Force
}

Write-Host "> Creating save backup from $savedPath"
Compress-Archive -LiteralPath $savedPath -DestinationPath $archivePath -CompressionLevel Optimal -Force

$archiveSizeMb = [math]::Round(((Get-Item $archivePath).Length / 1MB), 2)
Write-Host "> Backup created: $archivePath"
Write-Host "> Backup size: $archiveSizeMb MB"
Write-Host "> Server executable: $serverExe"