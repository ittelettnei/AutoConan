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

    Write-Host "> Restarting update_modules.ps1 with administrative privileges..."
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

function Invoke-SteamCmd {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    if (-not (Test-Path $steamCmd)) {
        throw "SteamCMD not found: $steamCmd"
    }

    Write-Host "> $StepName"
    & $steamCmd @Args

    if ($LASTEXITCODE -ne 0) {
        throw "SteamCMD failed during '$StepName' with exit code $LASTEXITCODE"
    }
}

function Invoke-LocalScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Args,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    Write-Host "> $StepName"
    & $currentShell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Args

    if ($LASTEXITCODE -ne 0) {
        throw "$StepName failed with exit code $LASTEXITCODE"
    }
}

function Get-DedicatedServerLauncherModList {
    param(
        [Parameter(Mandatory)][string]$ServerSettingsPath
    )

    if (-not (Test-Path $ServerSettingsPath)) {
        return @()
    }

    $line = Get-Content -Path $ServerSettingsPath | Where-Object {
        $_ -match '^\s*DedicatedServerLauncherModList\s*='
    } | Select-Object -First 1

    if (-not $line) {
        return @()
    }

    $rawValue = ($line -split '=', 2)[1]
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return @()
    }

    return @(
        $rawValue.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Sync-ConanModList {
    param(
        [Parameter(Mandatory)][string[]]$ConfiguredEntries,
        [Parameter(Mandatory)][string]$WorkshopCachePath,
        [Parameter(Mandatory)][string]$ModsPath
    )

    if ($ConfiguredEntries.Count -eq 0) {
        return
    }

    $modListEntries = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $ConfiguredEntries) {
        if ($entry -match '^\d+$') {
            $pak = Get-ChildItem -Path (Join-Path $WorkshopCachePath $entry) -Filter *.pak -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pak) {
                $modListEntries.Add($pak.Name)
            }
            continue
        }

        if (Test-Path $entry) {
            $modListEntries.Add((Split-Path -Leaf $entry))
        }
    }

    if ($modListEntries.Count -eq 0) {
        return
    }

    $modListPath = Join-Path $ModsPath "modlist.txt"
    Set-Content -Path $modListPath -Value $modListEntries -Encoding ASCII
    Write-Host "> Regenerated modlist.txt with $($modListEntries.Count) entries."
}

$serverBasePath = Join-Path $BasePath $InstanceName
$steamPath = Join-Path $serverBasePath "steamcmd"
$serverInstallPath = Join-Path $serverBasePath "gamefiles"
$modCacheBasePath = Join-Path $steamPath "modcache"
$steamCmd = Join-Path $steamPath "steamcmd.exe"
$serverExe = Resolve-ServerExecutablePath -InstallPath $serverInstallPath
$serverAppId = "443030"
$steamWorkshopScript = Join-Path $steamPath "update-conan-mods.txt"
$configRoot = Join-Path $serverInstallPath "ConanSandbox\Saved\Config\WindowsServer"
$serverSettingsPath = Join-Path $configRoot "ServerSettings.ini"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stopScript = Join-Path $scriptRoot "stop_server.ps1"
$startScript = Join-Path $scriptRoot "start_server.ps1"
$backupScript = Join-Path $scriptRoot "backup_save.ps1"
$currentShell = (Get-Process -Id $PID).Path

$enableWorkshopSync = Test-Path $steamWorkshopScript
$workshopAppId = "440900"
$workshopCachePath = Join-Path $modCacheBasePath "steamapps\workshop\content\$workshopAppId"
$targetModsPath = Join-Path $serverInstallPath "ConanSandbox\Mods"
$modManifest = Join-Path $modCacheBasePath "steamapps\workshop\appworkshop_$workshopAppId.acf"
$minMinutesBetweenModUpdates = 120

$serverWasRunning = @(Get-InstanceProcesses -InstallPath $serverInstallPath).Count -gt 0

try {
    if ($serverWasRunning) {
        Invoke-LocalScript -StepName "Stopping instance '$InstanceName' before backup/update" -ScriptPath $stopScript -Args @(
            "-BasePath", $BasePath,
            "-InstanceName", $InstanceName
        )

        Write-Host "> Verifying server has fully stopped..."
        $maxWaitSeconds = 60
        $elapsed = 0
        while (@(Get-InstanceProcesses -InstallPath $serverInstallPath).Count -gt 0 -and $elapsed -lt $maxWaitSeconds) {
            Write-Host "> Waiting for server process to exit (${elapsed}/${maxWaitSeconds} seconds)..."
            Start-Sleep -Seconds 2
            $elapsed += 2
        }

        if (@(Get-InstanceProcesses -InstallPath $serverInstallPath).Count -gt 0) {
            throw "Server process did not exit within $maxWaitSeconds seconds. Backup aborted for safety."
        }
        Write-Host "> Server confirmed stopped. Safe to proceed with backup."
    }

    Invoke-LocalScript -StepName "Creating save backup for instance '$InstanceName'" -ScriptPath $backupScript -Args @(
        "-BasePath", $BasePath,
        "-InstanceName", $InstanceName
    )

    Invoke-SteamCmd -StepName "Updating Conan Exiles dedicated server" -Args @(
        "+force_install_dir", $serverInstallPath,
        "+login", "anonymous",
        "+app_update", $serverAppId, "validate",
        "+quit"
    )

    if (-not $enableWorkshopSync) {
        Write-Host "> Workshop sync is disabled. Server update complete."
        return
    }

    $shouldRunModUpdate = $true
    if (Test-Path $modManifest) {
        $ageMinutes = (New-TimeSpan -Start (Get-Item $modManifest).LastWriteTime -End (Get-Date)).TotalMinutes
        if ($ageMinutes -lt $minMinutesBetweenModUpdates) {
            Write-Host "> Skipping workshop download (last update $([math]::Round($ageMinutes,1)) minutes ago)."
            $shouldRunModUpdate = $false
        }
    }

    if ($shouldRunModUpdate) {
        Invoke-SteamCmd -StepName "Updating workshop content" -Args @(
            "+runscript", $steamWorkshopScript
        )
    }

    New-Item -Path $targetModsPath -ItemType Directory -Force | Out-Null

    Write-Host "> Syncing workshop files to server Mods folder..."
    Get-ChildItem -Path $workshopCachePath -Recurse -Filter *.pak -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sourcePak = $_.FullName
        $destPak = Join-Path $targetModsPath $_.Name

        if ((-not (Test-Path $destPak)) -or ((Get-FileHash $sourcePak).Hash -ne (Get-FileHash $destPak).Hash)) {
            Copy-Item $sourcePak -Destination $destPak -Force
            Write-Host "> Updated: $($_.Name)"
        }
        else {
            Write-Host "- Up to date: $($_.Name)"
        }
    }

    $configuredMods = Get-DedicatedServerLauncherModList -ServerSettingsPath $serverSettingsPath
    Sync-ConanModList -ConfiguredEntries $configuredMods -WorkshopCachePath $workshopCachePath -ModsPath $targetModsPath

    Write-Host "> Conan update and workshop sync complete."
}
finally {
    if ($serverWasRunning) {
        Invoke-LocalScript -StepName "Starting instance '$InstanceName' after backup/update" -ScriptPath $startScript -Args @(
            "-BasePath", $BasePath,
            "-InstanceName", $InstanceName,
            "-RunMode", "Background"
        )
    }
}