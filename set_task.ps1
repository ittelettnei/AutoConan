
$Action = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument "/r /f /t 0"
$Trigger = New-ScheduledTaskTrigger -Daily -At 3:00AM
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "NightlyRestart" -Action $Action -Trigger $Trigger -Principal $Principal
