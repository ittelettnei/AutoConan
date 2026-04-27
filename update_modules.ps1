# Paths
$steamCmd = "C:\Steam\steamcmd.exe"
$steamScript = "C:\Steam\update-mods.txt"  # Your own mod list script
$serverInstallPath = "C:\ConanServer"
$cachePath = "C:\ConanModsCache\steamapps\workshop\content\440900"
$targetPath = Join-Path $serverInstallPath "ConanSandbox\Mods"
$modManifest = "C:\ConanModsCache\steamapps\workshop\appworkshop_440900.acf"
$minMinutesBetweenModUpdates = 120  # skip mod re-check if cache was touched more recently than this

# Run your update-mods.txt script via SteamCMD (script handles force_install_dir + login + quit)
$shouldRunModUpdate = $true
if (Test-Path $modManifest) {
    $ageMinutes = (New-TimeSpan -Start (Get-Item $modManifest).LastWriteTime -End (Get-Date)).TotalMinutes
    if ($ageMinutes -lt $minMinutesBetweenModUpdates) {
        Write-Host "> Skipping mod download (last update $([math]::Round($ageMinutes,1)) minutes ago)."
        $shouldRunModUpdate = $false
    }
}

if ($shouldRunModUpdate) {
    Write-Host "> Running SteamCMD to update mods..."
    $steamCmdArgsMods = @(
        "+runscript", $steamScript
    )
    & $steamCmd @steamCmdArgsMods
}

# Update the Conan Exiles dedicated server
Write-Host "> Running SteamCMD to update Conan Exiles..."
$steamCmdArgsServer = @(
    "+force_install_dir", $serverInstallPath,
    "+login", "anonymous",
    "+app_update", "443030", "validate",
    "+quit"
)
& $steamCmd @steamCmdArgsServer 

# Ensure target path exists
New-Item -Path $targetPath -ItemType Directory -Force | Out-Null

# Sync .pak files from cache to live server folder
Write-Host "> Syncing .pak files from cache to server..."

Get-ChildItem -Path $cachePath -Recurse -Filter *.pak | ForEach-Object {
    $sourcePak = $_.FullName
    $destPak = Join-Path $targetPath $_.Name

    if ((-Not (Test-Path $destPak)) -or ((Get-FileHash $sourcePak).Hash -ne (Get-FileHash $destPak).Hash)) {
        Copy-Item $sourcePak -Destination $destPak -Force
        Write-Host "> Updated: $($_.Name)"
    } else {
        Write-Host "- Up to date: $($_.Name)"
    }
}

Write-Host "> All mods checked and synced."
