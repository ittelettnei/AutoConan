[CmdletBinding()]
param(
    [string]$BasePath = "C:\servers",
    [Parameter(Mandatory)][string]$InstanceName
)

$ErrorActionPreference = "Stop"

$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$sharedRestartTaskName = "NightlyRestart"
$taskNamesToRemove = @(
    "ConanNightlyUpdate-$instanceKey",
    "ConanStartOnBoot-$instanceKey"
)

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $quotedScriptPath = '"{0}"' -f $scriptPath
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -BasePath `"$BasePath`" -InstanceName `"$InstanceName`""

    Write-Host "> Restarting unset_task.ps1 with administrative privileges..."
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -Verb RunAs | Out-Null
    exit 0
}

$removedTasks = @()
$missingTasks = @()

foreach ($taskName in $taskNamesToRemove) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        $removedTasks += $taskName
    }
    else {
        $missingTasks += $taskName
    }
}

$restartTask = Get-ScheduledTask -TaskName $sharedRestartTaskName -ErrorAction SilentlyContinue

if ($removedTasks.Count -gt 0) {
    Write-Host "Removed scheduled tasks: $($removedTasks -join ', ')"
}
else {
    Write-Host "No matching instance-specific scheduled tasks were found for instance '$InstanceName'."
}

if ($missingTasks.Count -gt 0) {
    Write-Host "Tasks not present: $($missingTasks -join ', ')"
}

if ($null -ne $restartTask) {
    Write-Host "Preserved shared restart task: $sharedRestartTaskName"
}
else {
    Write-Warning "Shared restart task '$sharedRestartTaskName' was not found. No restart tasks were modified."
}

Write-Host "Rollback target instance: $BasePath\$InstanceName"