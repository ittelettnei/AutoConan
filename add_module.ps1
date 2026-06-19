[CmdletBinding()]
param(
    [string]$BasePath = "C:\servers",
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][Alias("ModId", "WorkshopItemId")][ValidatePattern('^\d+$')][string]$ModuleId,
    [Alias("ReplaceModId", "ReplaceWorkshopItemId")][ValidatePattern('^\d+$')][string[]]$ReplaceModuleId = @(),
    [switch]$QueueOnly
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
    $quotedModuleId = '"{0}"' -f $ModuleId
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -BasePath $quotedBasePath -InstanceName $quotedInstanceName -ModuleId $quotedModuleId"

    foreach ($replacementId in $ReplaceModuleId) {
        $quotedReplacementId = '"{0}"' -f $replacementId
        $argumentList = "$argumentList -ReplaceModuleId $quotedReplacementId"
    }

    if ($QueueOnly.IsPresent) {
        $argumentList = "$argumentList -QueueOnly"
    }

    Write-Host "> Restarting add_module.ps1 with administrative privileges..."
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

function Stop-InstanceForModuleEdit {
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

function Start-InstanceAfterModuleEdit {
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

    throw "Instance '$InstanceName' did not start within $maxWaitSeconds seconds after adding module '$ModuleId'."
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

function ConvertTo-ModuleEntryList {
    param(
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-LineIndex {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Pattern
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $Pattern) {
            return $i
        }
    }

    return -1
}

function Test-WorkshopScriptContainsModule {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$WorkshopAppId,
        [Parameter(Mandatory)][string]$WorkshopModuleId
    )

    $pattern = '^\s*\+?workshop_download_item\s+' + [regex]::Escape($WorkshopAppId) + '\s+' + [regex]::Escape($WorkshopModuleId) + '(\s|$)'
    return [bool]($Lines | Where-Object { $_ -match $pattern } | Select-Object -First 1)
}

function Set-WorkshopScriptModules {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ModCachePath,
        [Parameter(Mandatory)][string]$WorkshopAppId,
        [Parameter(Mandatory)][string[]]$ModuleIds,
        [string[]]$RemoveModuleIds = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) {
        foreach ($line in @(Get-Content -Path $Path)) {
            $lines.Add([string]$line)
        }
    }

    $originalText = $lines -join "`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\+(force_install_dir|login|workshop_download_item|quit)(\s.*)?$') {
            $lines[$i] = ("{0}{1}" -f $matches[1], $matches[2]).TrimEnd()
        }
    }

    if ($RemoveModuleIds.Count -gt 0) {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            foreach ($removeModuleId in $RemoveModuleIds) {
                $removePattern = '^\s*workshop_download_item\s+' + [regex]::Escape($WorkshopAppId) + '\s+' + [regex]::Escape($removeModuleId) + '(\s|$)'
                if ($lines[$i] -match $removePattern) {
                    $lines.RemoveAt($i)
                    break
                }
            }
        }
    }

    $forceInstallLine = "force_install_dir $ModCachePath"
    $forceInstallIndex = Get-LineIndex -Lines $lines -Pattern '^\s*\+?force_install_dir\s+'
    if ($forceInstallIndex -ge 0) {
        $lines[$forceInstallIndex] = $forceInstallLine
    }
    else {
        $lines.Insert(0, $forceInstallLine)
        $forceInstallIndex = 0
    }

    $loginIndex = Get-LineIndex -Lines $lines -Pattern '^\s*\+?login\s+'
    if ($loginIndex -ge 0) {
        $lines[$loginIndex] = "login anonymous"
    }
    else {
        $lines.Insert(($forceInstallIndex + 1), "login anonymous")
    }

    foreach ($configuredModuleId in ($ModuleIds | Select-Object -Unique)) {
        if (Test-WorkshopScriptContainsModule -Lines $lines -WorkshopAppId $WorkshopAppId -WorkshopModuleId $configuredModuleId) {
            continue
        }

        $downloadLine = "workshop_download_item $WorkshopAppId $configuredModuleId validate"
        $quitIndex = Get-LineIndex -Lines $lines -Pattern '^\s*\+?quit\s*$'
        if ($quitIndex -ge 0) {
            $lines.Insert($quitIndex, $downloadLine)
        }
        else {
            $lines.Add($downloadLine)
        }
    }

    $quitIndex = Get-LineIndex -Lines $lines -Pattern '^\s*\+?quit\s*$'
    if ($quitIndex -ge 0) {
        $lines[$quitIndex] = "quit"
    }
    else {
        $lines.Add("quit")
    }

    $updatedText = $lines -join "`n"
    if ($updatedText -ne $originalText) {
        Set-Content -Path $Path -Value $lines -Encoding ASCII
        return $true
    }

    return $false
}

function Invoke-SteamCmd {
    param(
        [Parameter(Mandatory)][string]$SteamCmdPath,
        [Parameter(Mandatory)][string[]]$Args,
        [Parameter(Mandatory)][string]$StepName
    )

    if (-not (Test-Path $SteamCmdPath)) {
        throw "SteamCMD not found: $SteamCmdPath"
    }

    Write-Host "> $StepName"
    & $SteamCmdPath @Args

    if ($LASTEXITCODE -ne 0) {
        throw "SteamCMD failed during '$StepName' with exit code $LASTEXITCODE"
    }
}

function Sync-WorkshopPakFiles {
    param(
        [Parameter(Mandatory)][string]$WorkshopCachePath,
        [Parameter(Mandatory)][string]$TargetModsPath
    )

    New-Item -Path $TargetModsPath -ItemType Directory -Force | Out-Null

    $pakFiles = @(Get-ChildItem -Path $WorkshopCachePath -Recurse -Filter *.pak -File -ErrorAction SilentlyContinue)
    if ($pakFiles.Count -eq 0) {
        throw "No .pak files were found under workshop cache path: $WorkshopCachePath"
    }

    foreach ($pak in $pakFiles) {
        $sourcePak = $pak.FullName
        $destPak = Join-Path $TargetModsPath $pak.Name

        if ((-not (Test-Path $destPak)) -or ((Get-FileHash $sourcePak).Hash -ne (Get-FileHash $destPak).Hash)) {
            Copy-Item $sourcePak -Destination $destPak -Force
            Write-Host "> Updated: $($pak.Name)"
        }
        else {
            Write-Host "- Up to date: $($pak.Name)"
        }
    }
}

function Set-ConanModList {
    param(
        [Parameter(Mandatory)][string[]]$ConfiguredEntries,
        [Parameter(Mandatory)][string]$WorkshopCachePath,
        [Parameter(Mandatory)][string]$ModsPath
    )

    $modListEntries = New-Object System.Collections.Generic.List[string]
    $missingEntries = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $ConfiguredEntries) {
        if ($entry -match '^\d+$') {
            $pak = Get-ChildItem -Path (Join-Path $WorkshopCachePath $entry) -Recurse -Filter *.pak -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pak) {
                $modListEntries.Add($pak.Name)
            }
            else {
                $missingEntries.Add($entry)
            }
            continue
        }

        if (Test-Path $entry) {
            $modListEntries.Add((Split-Path -Leaf $entry))
        }
        else {
            $modListEntries.Add($entry)
        }
    }

    if ($missingEntries.Count -gt 0) {
        throw "No .pak file was found for configured module ID(s): $($missingEntries -join ', ')"
    }

    if ($modListEntries.Count -eq 0) {
        throw "No Conan modlist entries were resolved from DedicatedServerLauncherModList."
    }

    New-Item -Path $ModsPath -ItemType Directory -Force | Out-Null
    $modListPath = Join-Path $ModsPath "modlist.txt"
    Set-Content -Path $modListPath -Value $modListEntries -Encoding ASCII
    Write-Host "> Regenerated modlist.txt with $($modListEntries.Count) entries."

    return @($modListEntries)
}

function Remove-ReplacedModulePakFiles {
    param(
        [Parameter(Mandatory)][string[]]$ModuleIds,
        [Parameter(Mandatory)][string]$WorkshopCachePath,
        [Parameter(Mandatory)][string]$ModsPath,
        [Parameter(Mandatory)][string[]]$ActiveModListEntries
    )

    foreach ($replacedModuleId in ($ModuleIds | Select-Object -Unique)) {
        $replacedPakFiles = @(Get-ChildItem -Path (Join-Path $WorkshopCachePath $replacedModuleId) -Recurse -Filter *.pak -File -ErrorAction SilentlyContinue)

        foreach ($replacedPak in $replacedPakFiles) {
            if ($ActiveModListEntries -contains $replacedPak.Name) {
                continue
            }

            $targetPak = Join-Path $ModsPath $replacedPak.Name
            if (Test-Path $targetPak) {
                Remove-Item -Path $targetPak -Force
                Write-Host "> Removed replaced module pak from Mods folder: $($replacedPak.Name)"
            }
        }
    }
}

$serverRoot = Join-Path $BasePath $InstanceName
$steamPath = Join-Path $serverRoot "steamcmd"
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$modCachePath = Join-Path $steamPath "modcache"
$steamCmd = Join-Path $steamPath "steamcmd.exe"
$workshopScriptPath = Join-Path $steamPath "update-conan-mods.txt"
$configRoot = Join-Path $gameFilesPath "ConanSandbox\Saved\Config\WindowsServer"
$serverSettingsPath = Join-Path $configRoot "ServerSettings.ini"
$targetModsPath = Join-Path $gameFilesPath "ConanSandbox\Mods"
$workshopAppId = "440900"
$workshopCachePath = Join-Path $modCachePath "steamapps\workshop\content\$workshopAppId"
$moduleWorkshopPath = Join-Path $workshopCachePath $ModuleId
$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$startupTaskName = "ConanStartOnBoot-$instanceKey"

if (-not (Test-Path $gameFilesPath)) {
    throw "Instance gamefiles folder was not found: $gameFilesPath"
}

if (-not (Test-Path $serverSettingsPath)) {
    throw "ServerSettings.ini was not found for instance '$InstanceName': $serverSettingsPath"
}

if (-not $QueueOnly -and -not (Test-Path $steamCmd)) {
    throw "SteamCMD not found: $steamCmd"
}

New-Item -Path $steamPath -ItemType Directory -Force | Out-Null
New-Item -Path $modCachePath -ItemType Directory -Force | Out-Null

$currentModListValue = [string](Get-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key "DedicatedServerLauncherModList")
$configuredEntries = [System.Collections.Generic.List[string]]::new()
foreach ($entry in ConvertTo-ModuleEntryList -Value $currentModListValue) {
    if (-not $configuredEntries.Contains($entry)) {
        $configuredEntries.Add($entry)
    }
}

$requestedReplacementIds = @($ReplaceModuleId | Select-Object -Unique)
$removedModuleIds = New-Object System.Collections.Generic.List[string]
foreach ($replacementId in $requestedReplacementIds) {
    while ($configuredEntries.Contains($replacementId)) {
        [void]$configuredEntries.Remove($replacementId)
        if (-not $removedModuleIds.Contains($replacementId)) {
            $removedModuleIds.Add($replacementId)
        }
    }
}

$moduleWasAlreadyConfigured = $configuredEntries.Contains($ModuleId)
if (-not $moduleWasAlreadyConfigured) {
    $configuredEntries.Add($ModuleId)
}

$numericModuleIds = @($configuredEntries | Where-Object { $_ -match '^\d+$' })
$instanceWasRunning = @(Get-InstanceProcesses -InstallPath $gameFilesPath).Count -gt 0
$backupFolder = $null
$configWasChanged = (-not $moduleWasAlreadyConfigured) -or ($removedModuleIds.Count -gt 0)
$scriptWasChanged = $false
$runningProcesses = @()

if ($instanceWasRunning) {
    Write-Host "> Stopping instance '$InstanceName' before adding module '$ModuleId'..."
    Stop-InstanceForModuleEdit -InstallPath $gameFilesPath -StartupTaskName $startupTaskName
}
else {
    Write-Host "> Instance '$InstanceName' is not currently running. Adding module while it is stopped."
}

try {
    if ($configWasChanged) {
        $backupDate = Get-Date
        $backupFolder = Join-Path $serverRoot (Join-Path (Join-Path "config_backups" ($backupDate.ToString("yyyy\MM\dd"))) ("server-settings-before-module-$ModuleId-" + $backupDate.ToString("yyyyMMdd-HHmmss")))
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
        Copy-Item -Path $serverSettingsPath -Destination (Join-Path $backupFolder "ServerSettings.ini") -Force

        Set-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key "DedicatedServerLauncherModList" -Value ($configuredEntries -join ',')
        if ($removedModuleIds.Count -gt 0) {
            Write-Host "> Removed replaced module ID(s) from DedicatedServerLauncherModList: $($removedModuleIds -join ', ')"
        }

        if (-not $moduleWasAlreadyConfigured) {
            Write-Host "> Added module '$ModuleId' to DedicatedServerLauncherModList."
        }

        Write-Host "> Backed up current ServerSettings.ini to $backupFolder"
    }
    else {
        Write-Host "- Module '$ModuleId' is already present in DedicatedServerLauncherModList."
    }

    $scriptWasChanged = Set-WorkshopScriptModules -Path $workshopScriptPath -ModCachePath $modCachePath -WorkshopAppId $workshopAppId -ModuleIds $numericModuleIds -RemoveModuleIds $requestedReplacementIds
    if ($scriptWasChanged) {
        Write-Host "> Updated workshop download script: $workshopScriptPath"
    }
    else {
        Write-Host "- Workshop download script already contains module '$ModuleId'."
    }

    $verifiedEntries = ConvertTo-ModuleEntryList -Value ([string](Get-IniValue -Path $serverSettingsPath -Section "ServerSettings" -Key "DedicatedServerLauncherModList"))
    if ($verifiedEntries -notcontains $ModuleId) {
        throw "Module '$ModuleId' was not found in DedicatedServerLauncherModList after writing ServerSettings.ini."
    }

    if ($QueueOnly) {
        Write-Host "> Module '$ModuleId' has been queued. Run update_modules.ps1 later to download and sync workshop files."
    }
    else {
        Invoke-SteamCmd -SteamCmdPath $steamCmd -StepName "Downloading configured Conan workshop modules" -Args @(
            "+runscript", $workshopScriptPath
        )

        $modulePakFiles = @(Get-ChildItem -Path $moduleWorkshopPath -Recurse -Filter *.pak -File -ErrorAction SilentlyContinue)
        if ($modulePakFiles.Count -eq 0) {
            throw "Module '$ModuleId' downloaded without a detectable .pak under: $moduleWorkshopPath"
        }

        Write-Host "> Syncing workshop .pak files into the server Mods folder..."
        Sync-WorkshopPakFiles -WorkshopCachePath $workshopCachePath -TargetModsPath $targetModsPath
        $activeModListEntries = @(Set-ConanModList -ConfiguredEntries $verifiedEntries -WorkshopCachePath $workshopCachePath -ModsPath $targetModsPath)

        if ($requestedReplacementIds.Count -gt 0) {
            Remove-ReplacedModulePakFiles -ModuleIds $requestedReplacementIds -WorkshopCachePath $workshopCachePath -ModsPath $targetModsPath -ActiveModListEntries $activeModListEntries
        }
    }
}
finally {
    if ($instanceWasRunning) {
        Write-Host "> Starting instance '$InstanceName' after module update..."
        $runningProcesses = @(Start-InstanceAfterModuleEdit -InstallPath $gameFilesPath -StartupTaskName $startupTaskName)
    }
}

Write-Host "> Module add complete for instance '$InstanceName'."
Write-Host "> Module ID: $ModuleId"
Write-Host "> Workshop script: $workshopScriptPath"
Write-Host "> ServerSettings.ini: $serverSettingsPath"

if ($backupFolder) {
    Write-Host "> Config backup: $backupFolder"
}

if (-not $QueueOnly) {
    Write-Host "> Mods folder: $targetModsPath"
}

if ($instanceWasRunning) {
    $processIds = ($runningProcesses | ForEach-Object { $_.ProcessId }) -join ", "
    Write-Host "> Running PID(s): $processIds"
}
else {
    Write-Host "> Instance was stopped before this script ran, so it was left stopped."
}