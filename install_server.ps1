param(
    [string]$ServerAppId = "443030",

    [string]$BasePath = "C:\servers",

    [Parameter(Mandatory)][string]$InstanceName,

    [switch]$CreateWorkshopScript,

    [switch]$AllowExistingInstanceInstall,

    [switch]$UpdateExistingConfig,

    [Parameter(Mandatory)][string]$ServerName,

    [Parameter(Mandatory)][AllowEmptyString()][string]$ServerPassword
)

$ErrorActionPreference = "Stop"

$serverRoot = Join-Path $BasePath $InstanceName
$steamPath = Join-Path $serverRoot "steamcmd"
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$modCachePath = Join-Path $steamPath "modcache"
$steamCmdZip = Join-Path $steamPath "steamcmd.zip"
$steamCmdExe = Join-Path $steamPath "steamcmd.exe"
$steamCmdUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
$workshopScriptPath = Join-Path $steamPath "update-conan-mods.txt"
$configRoot = Join-Path $gameFilesPath "ConanSandbox\Saved\Config\WindowsServer"
$engineIniPath = Join-Path $configRoot "Engine.ini"
$serverSettingsPath = Join-Path $configRoot "ServerSettings.ini"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultConfigRoot = Join-Path $scriptRoot "defaults\ConanSandbox\Saved\Config\WindowsServer"
$defaultEngineIniPath = Join-Path $defaultConfigRoot "Engine.ini"
$defaultServerSettingsPath = Join-Path $defaultConfigRoot "ServerSettings.ini"
$steamCmdWasDownloaded = $false

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

function Stop-ConanServer {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$InstallPath
    )

    if ($null -ne $Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }

    if ($InstallPath) {
        Get-InstanceProcesses -InstallPath $InstallPath | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-ConanServer {
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    $serverExe = Resolve-ServerExecutablePath -InstallPath $InstallPath
    $workingDirectory = Split-Path -Parent $serverExe

    return Start-Process -FilePath $serverExe -ArgumentList "-log" -WorkingDirectory $workingDirectory -PassThru
}

function Ensure-ServerConfigExists {
    if ((Test-Path $engineIniPath) -and (Test-Path $serverSettingsPath)) {
        return
    }

    Write-Host "> Generating initial Conan config files (first server startup)..."
    $bootstrapProcess = Start-ConanServer -InstallPath $gameFilesPath

    for ($i = 0; $i -lt 45 -and ((-not (Test-Path $engineIniPath)) -or (-not (Test-Path $serverSettingsPath))); $i++) {
        Start-Sleep -Seconds 2
    }

    Stop-ConanServer -Process $bootstrapProcess -InstallPath $gameFilesPath

    if (-not (Test-Path $engineIniPath)) {
        New-Item -Path $engineIniPath -ItemType File -Force | Out-Null
    }

    if (-not (Test-Path $serverSettingsPath)) {
        New-Item -Path $serverSettingsPath -ItemType File -Force | Out-Null
    }
}

function Copy-DefaultConfigFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path $SourcePath)) {
        return $false
    }

    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
    return $true
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

$instanceAlreadyInitialized =
    (Test-Path $engineIniPath) -or
    (Test-Path $serverSettingsPath) -or
    ((Get-ServerExecutableCandidates -InstallPath $gameFilesPath | Where-Object { Test-Path $_ }).Count -gt 0) -or
    (Test-Path $steamCmdExe)

if ($instanceAlreadyInitialized -and -not $AllowExistingInstanceInstall) {
    throw @"
Instance '$InstanceName' already appears to be installed under '$serverRoot'.
To prevent accidental overwrite, install_server.ps1 stops here by default.

Recommended: run update_modules.ps1 for routine updates.
If you intentionally want to rerun install, use -AllowExistingInstanceInstall.
If you also want to rewrite Engine.ini values, add -UpdateExistingConfig.
"@
}

Write-Host "> Preparing Conan server folders under $serverRoot"
New-Item -Path $serverRoot -ItemType Directory -Force | Out-Null
New-Item -Path $steamPath -ItemType Directory -Force | Out-Null
New-Item -Path $gameFilesPath -ItemType Directory -Force | Out-Null
New-Item -Path $modCachePath -ItemType Directory -Force | Out-Null
New-Item -Path $configRoot -ItemType Directory -Force | Out-Null

if (-not (Test-Path $steamCmdExe)) {
    Write-Host "> Downloading SteamCMD..."
    Invoke-WebRequest -Uri $steamCmdUrl -OutFile $steamCmdZip

    Write-Host "> Extracting SteamCMD..."
    Expand-Archive -Path $steamCmdZip -DestinationPath $steamPath -Force
    $steamCmdWasDownloaded = $true
}
else {
    Write-Host "- SteamCMD already present at $steamCmdExe"
}

if ($steamCmdWasDownloaded) {
    Write-Host "> Bootstrapping SteamCMD..."
    & $steamCmdExe "+quit"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "- SteamCMD bootstrap exited with code $LASTEXITCODE; continuing with the updated client."
    }
}

Write-Host "> Installing or updating Conan Exiles dedicated server..."
$steamCmdArgs = @(
    "+force_install_dir", $gameFilesPath,
    "+login", "anonymous",
    "+app_update", $ServerAppId, "validate",
    "+quit"
)

$maxInstallAttempts = if ($steamCmdWasDownloaded) { 2 } else { 1 }
$installSucceeded = $false

for ($attempt = 1; $attempt -le $maxInstallAttempts; $attempt++) {
    & $steamCmdExe @steamCmdArgs

    if ($LASTEXITCODE -eq 0) {
        $installSucceeded = $true
        break
    }

    if ($attempt -lt $maxInstallAttempts) {
        Write-Host "- SteamCMD install attempt $attempt exited with code $LASTEXITCODE; retrying once after bootstrap."
    }
}

if (-not $installSucceeded) {
    throw "SteamCMD failed with exit code $LASTEXITCODE"
}

if ($CreateWorkshopScript -and -not (Test-Path $workshopScriptPath)) {
    @(
        "force_install_dir $modCachePath",
        "login anonymous",
        "; add workshop_download_item 440900 <modId> validate commands here",
        "quit"
    ) | Set-Content -Path $workshopScriptPath -Encoding ASCII

    Write-Host "> Created workshop script template at $workshopScriptPath"
}

Ensure-ServerConfigExists

$existingServerName = [string](Get-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerName")
$existingPassword = [string](Get-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerPassword")

$shouldConfigureServerDescription =
    (-not $instanceAlreadyInitialized) -or
    $UpdateExistingConfig

if ($instanceAlreadyInitialized -and $AllowExistingInstanceInstall -and -not $UpdateExistingConfig) {
    Write-Host "- Existing instance detected. Engine.ini will not be modified unless -UpdateExistingConfig is specified."
}

if ($shouldConfigureServerDescription) {
    $copiedDefaultFiles = @()

    if (Copy-DefaultConfigFile -SourcePath $defaultEngineIniPath -DestinationPath $engineIniPath) {
        $copiedDefaultFiles += "Engine.ini"
    }

    if (Copy-DefaultConfigFile -SourcePath $defaultServerSettingsPath -DestinationPath $serverSettingsPath) {
        $copiedDefaultFiles += "ServerSettings.ini"
    }

    if ($copiedDefaultFiles.Count -gt 0) {
        Write-Host ("> Applied default config template from {0} ({1})" -f $defaultConfigRoot, ($copiedDefaultFiles -join ', '))
    }

    $configProcess = Start-ConanServer -InstallPath $gameFilesPath

    Start-Sleep -Seconds 5
    Stop-ConanServer -Process $configProcess -InstallPath $gameFilesPath

    Set-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerName" -Value $ServerName
    Set-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerPassword" -Value $ServerPassword
    Write-Host "> Applied server config to $engineIniPath"
}

$runningConanProcess = @(Get-InstanceProcesses -InstallPath $gameFilesPath)
if ($runningConanProcess.Count -eq 0) {
    Write-Host "> Starting Conan server..."
    $runningProcess = Start-ConanServer -InstallPath $gameFilesPath
    Start-Sleep -Seconds 5
    $runningConanProcess = @(Get-Process -Id $runningProcess.Id -ErrorAction SilentlyContinue)
}

if ($runningConanProcess.Count -eq 0) {
    throw "Conan server failed to start after install."
}

$finalServerName = [string](Get-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerName")
$finalPassword = [string](Get-IniValue -Path $engineIniPath -Section "OnlineSubsystem" -Key "ServerPassword")
$serverExe = Resolve-ServerExecutablePath -InstallPath $gameFilesPath

Write-Host "> Conan install complete."
Write-Host "> Instance root: $serverRoot"
Write-Host "> Game files: $gameFilesPath"
Write-Host "> SteamCMD: $steamCmdExe"
Write-Host "> Mod cache: $modCachePath"
Write-Host "> Server executable: $serverExe"
Write-Host "> Server name: $finalServerName"
Write-Host "> Password: $finalPassword"

if (-not [string]::IsNullOrWhiteSpace($existingServerName) -and $existingServerName -ne $finalServerName) {
    Write-Host "- Previous ServerName: $existingServerName"
}

if (-not [string]::IsNullOrWhiteSpace($existingPassword) -and $existingPassword -ne $finalPassword) {
    Write-Host "- Previous Password: $existingPassword"
}