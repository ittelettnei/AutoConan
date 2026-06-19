# AutoConan

Automation scripts for installing, updating, backing up, and scheduling one or more Conan Exiles dedicated server instances on Windows.

## Overview

This repo uses a per-instance layout:

- <BasePath>\<InstanceName>\steamcmd
- <BasePath>\<InstanceName>\gamefiles

Default BasePath is C:\servers.

The scripts that operate per instance are:

- install_server.ps1
- add_module.ps1
- update_modules.ps1
- apply_event_log_template.ps1
- start_server.ps1
- stop_server.ps1
- set_task.ps1
- unset_task.ps1
- backup_save.ps1
- check_task_status.ps1

The old one-off updater is kept in old_backup\ for reference only. The root scripts are the active automation path.

## What Each Script Does

- install_server.ps1: Creates the instance folder structure, installs SteamCMD, installs or updates the Conan Exiles dedicated server, boots the server once if needed to generate the WindowsServer ini files, copies the repo default Engine.ini and ServerSettings.ini templates when installing or when -UpdateExistingConfig is used, writes ServerName and ServerPassword into Engine.ini, and ensures the server process is running at the end.
- add_module.ps1: Adds a Steam Workshop module ID to one instance by updating update-conan-mods.txt and DedicatedServerLauncherModList, downloads/syncs workshop .pak files by default, regenerates modlist.txt, and restarts the instance if it was running.
- apply_event_log_template.ps1: Backs up the current per-instance ServerSettings.ini into a dated config_backups folder, applies the repo's event-log visibility, player-list privacy, and building-damage window template values to the live instance, and restarts the server so the change takes effect.
- backup_save.ps1: Refuses to back up a running instance and zips ConanSandbox\Saved into the instance backup folder.
- update_modules.ps1: Stops only the selected instance if it is running, runs backup_save.ps1, updates the server with SteamCMD, optionally syncs workshop mods when an update-conan-mods.txt script exists, and starts the instance again in background mode if it was running before the update.
- start_server.ps1: Starts one instance by triggering its scheduled start task.
- stop_server.ps1: Stops only the selected instance by matching the exact instance executable path and ending the instance start task.
- set_task.ps1: Registers the scheduled tasks used for nightly maintenance and start-on-boot.
- unset_task.ps1: Removes the instance-specific scheduled tasks and leaves the shared reboot task in place.
- check_task_status.ps1: Reports whether the expected scheduled tasks exist and shows their scheduler state, run history, and configured actions.

## Quick Start

1. Install one instance.
2. Optionally add workshop modules.
3. Register the scheduled tasks.
4. Verify task status.

Example install command:

```powershell
powershell -ExecutionPolicy Bypass -File .\install_server.ps1 -BasePath C:\servers -InstanceName conan -ServerName "Hyboria" -ServerPassword "ChangeMe123" -CreateWorkshopScript
```

Notes:

- InstanceName is required.
- ServerName is mandatory. If omitted, PowerShell prompts before install work starts.
- ServerPassword is mandatory so PowerShell prompts before install work starts, but it may be left blank to create a server without a password.
- Default Conan config templates are stored under defaults\ConanSandbox\Saved\Config\WindowsServer and are currently sourced from C:\ConanServer.
- The default Conan event-log template now keeps both PvE and PvP causer visibility at the private-server-friendly owner-or-admin level so players can identify who damaged their own buildings after Funcom's newer split visibility changes. It also keeps ShowOnlinePlayers disabled to reduce SteamID exposure through the online player list and restricts player-owned building damage to Friday/Saturday 18:00-23:00.
- install_server.ps1 guards against accidental second runs:
  - By default, if the instance already exists, the script aborts before making changes.
  - Use -AllowExistingInstanceInstall only when you intentionally want to rerun install or update steps.
  - Existing config is not rewritten unless you also pass -UpdateExistingConfig.

If you use workshop mods, review the generated script at C:\servers\<InstanceName>\steamcmd\update-conan-mods.txt.

## Add A Workshop Module To An Instance

Use add_module.ps1 with the Steam Workshop item ID for the Conan module you want to add:

```powershell
powershell -ExecutionPolicy Bypass -File .\add_module.ps1 -BasePath C:\servers -InstanceName conan -ModuleId 123456789
```

The script:

- Adds the ID to C:\servers\<InstanceName>\steamcmd\update-conan-mods.txt.
- Appends the ID to DedicatedServerLauncherModList in ServerSettings.ini without duplicating existing entries.
- Backs up ServerSettings.ini before changing it.
- Downloads the configured workshop modules through SteamCMD, copies .pak files into ConanSandbox\Mods, and regenerates modlist.txt.
- Stops and restarts the selected instance only when it was already running.

To only queue the module for the next scheduled update without downloading it immediately, add -QueueOnly:

```powershell
powershell -ExecutionPolicy Bypass -File .\add_module.ps1 -BasePath C:\servers -InstanceName conan -ModuleId 123456789 -QueueOnly
```

To replace a previously configured Workshop module ID at the same time:

```powershell
powershell -ExecutionPolicy Bypass -File .\add_module.ps1 -BasePath C:\servers -InstanceName conan -ModuleId 3721124998 -ReplaceModuleId 1417350098
```

## Apply Event Log And Building Damage Fixes To An Existing Instance

Funcom's 2025 event-log change split visibility into separate PvE and PvP settings, and private-server owners reported that useful attribution came back after changing those values again on their own servers.

This repo now keeps the template at:

- ShowOnlinePlayers=0
- EventLogCauserPrivacy=1
- EventLogPvECauserPrivacy=1
- EventLogPvPCauserPrivacy=1
- RestrictPVPBuildingDamageTime=True
- CanDamagePlayerOwnedStructures=True
- PVPBuildingDamageTimeFridayStart=1800
- PVPBuildingDamageTimeFridayEnd=2300
- PVPBuildingDamageTimeSaturdayStart=1800
- PVPBuildingDamageTimeSaturdayEnd=2300
- PVPBuildingDamageEnabledMonday=False
- PVPBuildingDamageEnabledTuesday=False
- PVPBuildingDamageEnabledWednesday=False
- PVPBuildingDamageEnabledThursday=False
- PVPBuildingDamageEnabledFriday=True
- PVPBuildingDamageEnabledSaturday=True
- PVPBuildingDamageEnabledSunday=False

To apply just those template values to an existing instance without overwriting the rest of your ServerSettings.ini, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\apply_event_log_template.ps1 -BasePath C:\servers -InstanceName conan
```

What the command does:

- Stops the selected instance before editing config.
- Copies the current ServerSettings.ini into C:\servers\<InstanceName>\config_backups\yyyy\MM\dd\server-settings-yyyyMMdd-HHmmss.
- Applies only the event-log visibility, online-player-list privacy, and building-damage window keys from the repo template.
- Starts the instance again and verifies that the config values were written.

Research note:

- I found good community evidence for the event-log visibility fix itself, including Funcom forum reports after the split PvE/PvP change.
- I did not find a documented ServerSettings.ini flag that globally removes SteamID from every Conan UI surface. This command applies the supported server-side privacy setting already in the template, ShowOnlinePlayers=0, but the known discussions about hiding SteamID everywhere else point to mod/dev-kit work rather than a dedicated-server config toggle.

## What set_task.ps1 Creates

set_task.ps1 self-elevates if needed and registers three scheduled tasks:

- ConanNightlyUpdate-<instance>: Daily at 04:30, runs update_modules.ps1 -BasePath <BasePath> -InstanceName <InstanceName> as SYSTEM with highest privileges.
- NightlyRestart: Daily at 05:00, shared across all instances, runs shutdown.exe /r /f /t 0 as SYSTEM.
- ConanStartOnBoot-<instance>: Runs at system startup with a one-minute delay and launches the Conan server executable with the instance gamefiles folder as the working directory.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\set_task.ps1 -BasePath C:\servers -InstanceName conan
```

## How The Server Runs After set_task.ps1

No Windows service is installed by this repo.

After set_task.ps1, the server is managed by Task Scheduler plus normal server processes:

- set_task.ps1 only registers future actions. It does not immediately start a stopped server.
- install_server.ps1 normally leaves the server running when installation finishes.
- During the nightly update window, ConanNightlyUpdate-<instance> runs update_modules.ps1.
- update_modules.ps1 checks whether the selected instance is already running. If it is, the script stops that instance, backs up the save data, updates the files, and starts the instance again in background mode.
- NightlyRestart then reboots the machine at 05:00.
- After Windows comes back up, ConanStartOnBoot-<instance> waits one minute and launches the Conan server executable directly.

The steady-state result is a normal Conan server process started by Task Scheduler, not a Windows service.

## Check Scheduled Task Status

Use the included status script to inspect the expected tasks for one instance:

```powershell
powershell -ExecutionPolicy Bypass -File .\check_task_status.ps1 -BasePath C:\servers -InstanceName conan
```

The script reports:

- Whether ConanNightlyUpdate-<instance> exists
- Whether the shared NightlyRestart task exists
- Whether ConanStartOnBoot-<instance> exists
- Task state, next run time, last run time, and last task result
- The command each task is configured to execute
- Whether the instance server executable exists at the expected path

## Manual Control

Start or stop a specific instance manually:

```powershell
powershell -ExecutionPolicy Bypass -File .\start_server.ps1 -BasePath C:\servers -InstanceName conan -RunMode Foreground
powershell -ExecutionPolicy Bypass -File .\start_server.ps1 -BasePath C:\servers -InstanceName conan -RunMode Background
powershell -ExecutionPolicy Bypass -File .\stop_server.ps1 -BasePath C:\servers -InstanceName conan
```

If you omit -RunMode, start_server.ps1 prompts for Foreground or Background. The implementation uses the registered scheduled task for both modes so Task Scheduler owns the launched process.

## Remove Scheduled Tasks

To remove the instance-specific tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\unset_task.ps1 -BasePath C:\servers -InstanceName conan
```

unset_task.ps1 removes:

- ConanNightlyUpdate-<instance>
- ConanStartOnBoot-<instance>

It does not remove the shared NightlyRestart task.

## Operational Notes

- The installer seeds ConanSandbox\Saved\Config\WindowsServer\Engine.ini and ServerSettings.ini from the repo templates under defaults\ConanSandbox\Saved\Config\WindowsServer, then writes ServerName and ServerPassword to Engine.ini under the OnlineSubsystem section. Leave ServerPassword blank if you want no server password.
- Existing instances should use apply_event_log_template.ps1 when you only want to push the event-log visibility, player-list privacy, and building-damage window fixes while keeping the rest of the live ServerSettings.ini intact.
- The updater only performs workshop sync when update-conan-mods.txt exists under the instance steamcmd folder.
- add_module.ps1 creates or updates update-conan-mods.txt for the selected instance and keeps numeric Workshop IDs in DedicatedServerLauncherModList as the source of mod load order.
- Workshop sync copies .pak files into ConanSandbox\Mods and will regenerate modlist.txt when DedicatedServerLauncherModList is present in ServerSettings.ini.
- These scripts intentionally keep server install paths instance-specific so multiple Conan Exiles instances can coexist on the same host.