[CmdletBinding()]
param(
    [string]$BasePath = "C:\servers",
    [Parameter(Mandatory)][string]$InstanceName
)

$ErrorActionPreference = "Stop"

$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'
$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$serverExeCandidates = @(
    (Join-Path $gameFilesPath "ConanSandboxServer.exe"),
    (Join-Path $gameFilesPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Shipping.exe"),
    (Join-Path $gameFilesPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Test.exe")
)
$serverExe = $serverExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$tasksToCheck = @(
    [pscustomobject]@{ Role = "Nightly update"; TaskName = "ConanNightlyUpdate-$instanceKey" },
    [pscustomobject]@{ Role = "Nightly restart"; TaskName = "NightlyRestart" },
    [pscustomobject]@{ Role = "Start on boot"; TaskName = "ConanStartOnBoot-$instanceKey" }
)

function Format-TaskTime {
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "-"
    }

    if ($Value -isnot [datetime]) {
        try {
            $Value = [datetime]$Value
        }
        catch {
            return [string]$Value
        }
    }

    if ($Value -le [datetime]::MinValue.AddSeconds(1)) {
        return "-"
    }

    return $Value.ToString("yyyy-MM-dd HH:mm:ss")
}

function Get-TaskSummary {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Role
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -eq $task) {
        return [pscustomobject]@{
            Role = $Role
            TaskName = $TaskName
            Present = $false
            State = "Missing"
            NextRunTime = "-"
            LastRunTime = "-"
            LastTaskResult = "-"
            RunAs = "-"
            Execute = "-"
            Arguments = "-"
            WorkingDirectory = "-"
        }
    }

    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $primaryAction = @($task.Actions | Select-Object -First 1)[0]

    return [pscustomobject]@{
        Role = $Role
        TaskName = $TaskName
        Present = $true
        State = [string]$task.State
        NextRunTime = Format-TaskTime -Value $info.NextRunTime
        LastRunTime = Format-TaskTime -Value $info.LastRunTime
        LastTaskResult = if ($null -eq $info.LastTaskResult) { "-" } else { [string]$info.LastTaskResult }
        RunAs = if ([string]::IsNullOrWhiteSpace($task.Principal.UserId)) { "-" } else { $task.Principal.UserId }
        Execute = if ($null -eq $primaryAction -or [string]::IsNullOrWhiteSpace($primaryAction.Execute)) { "-" } else { $primaryAction.Execute }
        Arguments = if ($null -eq $primaryAction -or [string]::IsNullOrWhiteSpace($primaryAction.Arguments)) { "-" } else { $primaryAction.Arguments }
        WorkingDirectory = if ($null -eq $primaryAction -or [string]::IsNullOrWhiteSpace($primaryAction.WorkingDirectory)) { "-" } else { $primaryAction.WorkingDirectory }
    }
}

$taskSummaries = foreach ($taskToCheck in $tasksToCheck) {
    Get-TaskSummary -TaskName $taskToCheck.TaskName -Role $taskToCheck.Role
}

Write-Host "Instance: $InstanceName"
Write-Host "Base path: $BasePath"
Write-Host "Instance root: $serverRoot"
Write-Host "Game files path: $gameFilesPath"
Write-Host "Server executable present: $([bool]$serverExe)"
Write-Host ""

$taskSummaries |
    Select-Object Role, TaskName, State, NextRunTime, LastRunTime, LastTaskResult |
    Format-Table -AutoSize

foreach ($taskSummary in $taskSummaries | Where-Object { $_.Present }) {
    Write-Host ""
    Write-Host "[$($taskSummary.Role)] $($taskSummary.TaskName)"
    Write-Host "  RunAs: $($taskSummary.RunAs)"
    Write-Host "  Execute: $($taskSummary.Execute)"

    if ($taskSummary.Arguments -ne "-") {
        Write-Host "  Arguments: $($taskSummary.Arguments)"
    }

    if ($taskSummary.WorkingDirectory -ne "-") {
        Write-Host "  WorkingDirectory: $($taskSummary.WorkingDirectory)"
    }
}

$missingTasks = @($taskSummaries | Where-Object { -not $_.Present })

if ($missingTasks.Count -gt 0) {
    Write-Warning "Missing tasks for instance '$InstanceName': $($missingTasks.TaskName -join ', ')"
}

if ($missingTasks.Count -eq $tasksToCheck.Count -and $serverExe) {
    Write-Host ""
    Write-Host "No scheduled tasks are currently registered for this instance."
    Write-Host "Run set_task.ps1 again from an elevated PowerShell window, or rerun it and accept the UAC prompt."
}