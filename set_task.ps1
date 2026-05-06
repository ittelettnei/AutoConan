param(
	[string]$BasePath = "C:\servers",
	[Parameter(Mandatory)][string]$InstanceName
)

$ErrorActionPreference = "Stop"

$instanceKey = $InstanceName -replace '[^A-Za-z0-9_-]', '-'

function Test-ExpectedTasksPresent {
	param(
		[Parameter(Mandatory)][string[]]$TaskNames
	)

	foreach ($taskName in $TaskNames) {
		if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
			return $false
		}
	}

	return $true
}

function Wait-ExpectedTasksPresent {
	param(
		[Parameter(Mandatory)][string[]]$TaskNames,
		[int]$MaxAttempts = 10,
		[int]$DelaySeconds = 1
	)

	for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
		if (Test-ExpectedTasksPresent -TaskNames $TaskNames) {
			return $true
		}

		if ($attempt -lt $MaxAttempts) {
			Start-Sleep -Seconds $DelaySeconds
		}
	}

	return $false
}

function Test-IsAdministrator {
	$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServerExecutableCandidates {
	param(
		[Parameter(Mandatory)][string]$InstallPath
	)

	return @(
		(Join-Path $InstallPath "ConanSandboxServer.exe"),
		(Join-Path $InstallPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Shipping.exe"),
		(Join-Path $InstallPath "ConanSandbox\Binaries\Win64\ConanSandboxServer-Win64-Test.exe")
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

if (-not (Test-IsAdministrator)) {
	$scriptPath = $MyInvocation.MyCommand.Path
	$quotedScriptPath = '"{0}"' -f $scriptPath
	$argumentList = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -BasePath `"$BasePath`" -InstanceName `"$InstanceName`""

	Write-Host "> Restarting set_task.ps1 with administrative privileges..."

	try {
		$process = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
	}
	catch {
		throw "Elevation was not completed. Task registration was canceled or failed to launch."
	}

	if ($process.ExitCode -ne 0) {
		throw "Elevated task registration failed with exit code $($process.ExitCode)."
	}

	Write-Host "Scheduled task registration completed for instance '$InstanceName'."
	return
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$updateScript = Join-Path $scriptRoot "update_modules.ps1"
$serverRoot = Join-Path $BasePath $InstanceName
$gameFilesPath = Join-Path $serverRoot "gamefiles"
$serverExe = Resolve-ServerExecutablePath -InstallPath $gameFilesPath
$sharedRestartTaskName = "NightlyRestart"
$legacyRestartTaskName = "ConanNightlyRestart"
$updateTaskName = "ConanNightlyUpdate-$instanceKey"
$startupTaskName = "ConanStartOnBoot-$instanceKey"
$expectedTaskNames = @(
	$updateTaskName,
	$sharedRestartTaskName,
	$startupTaskName
)

if (-not (Test-Path $updateScript)) {
	throw "Could not find update script at: $updateScript"
}

if (-not (Test-Path $serverExe)) {
	throw "Could not find server executable at: $serverExe"
}

$updateAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`" -BasePath `"$BasePath`" -InstanceName `"$InstanceName`""
$updateTrigger = New-ScheduledTaskTrigger -Daily -At 4:30AM
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

if (Get-ScheduledTask -TaskName "ConanNightlyUpdate" -ErrorAction SilentlyContinue) {
	Unregister-ScheduledTask -TaskName "ConanNightlyUpdate" -Confirm:$false
}

Register-ScheduledTask -TaskName $updateTaskName -Action $updateAction -Trigger $updateTrigger -Principal $principal -Force

$restartAction = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument "/r /f /t 0"
$restartTrigger = New-ScheduledTaskTrigger -Daily -At 5:00AM

if (Get-ScheduledTask -TaskName $legacyRestartTaskName -ErrorAction SilentlyContinue) {
	Unregister-ScheduledTask -TaskName $legacyRestartTaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $sharedRestartTaskName -Action $restartAction -Trigger $restartTrigger -Principal $principal -Force

$startupAction = New-ScheduledTaskAction -Execute $serverExe -Argument "-log" -WorkingDirectory (Split-Path -Parent $serverExe)
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$startupSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable
$startupTrigger.Delay = "PT1M"

Register-ScheduledTask -TaskName $startupTaskName -Action $startupAction -Trigger $startupTrigger -Principal $principal -Settings $startupSettings -Force

if (-not (Wait-ExpectedTasksPresent -TaskNames $expectedTaskNames)) {
	throw "Task registration finished without creating all expected tasks for instance '$InstanceName'."
}

Write-Host "Scheduled tasks created/updated: $updateTaskName, $sharedRestartTaskName, $startupTaskName"
