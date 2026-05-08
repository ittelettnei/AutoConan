# AutoConan

Automation scripts for installing, updating, backing up, and scheduling one or more Conan Exiles dedicated server instances on Windows.

## Overview

This repo uses a per-instance layout:

- <BasePath>\<InstanceName>\steamcmd
- <BasePath>\<InstanceName>\gamefiles

Default BasePath is C:\servers.

The scripts that operate per instance are:

- install_server.ps1
- update_modules.ps1
- start_server.ps1
- stop_server.ps1
- set_task.ps1
- unset_task.ps1
- backup_save.ps1
- check_task_status.ps1

The old one-off updater is kept in old_backup\ for reference only. The root scripts are the active automation path.

## What Each Script Does

- install_server.ps1: Creates the instance folder structure, installs SteamCMD, installs or updates the Conan Exiles dedicated server, boots the server once if needed to generate the WindowsServer ini files, copies the repo default Engine.ini and ServerSettings.ini templates when installing or when -UpdateExistingConfig is used, writes ServerName and ServerPassword into Engine.ini, and ensures the server process is running at the end.
- backup_save.ps1: Refuses to back up a running instance and zips ConanSandbox\Saved into the instance backup folder.
- update_modules.ps1: Stops only the selected instance if it is running, runs backup_save.ps1, updates the server with SteamCMD, optionally syncs workshop mods when an update-conan-mods.txt script exists, and starts the instance again in background mode if it was running before the update.
- start_server.ps1: Starts one instance by triggering its scheduled start task.
- stop_server.ps1: Stops only the selected instance by matching the exact instance executable path and ending the instance start task.
- set_task.ps1: Registers the scheduled tasks used for nightly maintenance and start-on-boot.
- unset_task.ps1: Removes the instance-specific scheduled tasks and leaves the shared reboot task in place.
- check_task_status.ps1: Reports whether the expected scheduled tasks exist and shows their scheduler state, run history, and configured actions.

## Quick Start

1. Install one instance.
2. Optionally prepare workshop sync.
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
- install_server.ps1 guards against accidental second runs:
  - By default, if the instance already exists, the script aborts before making changes.
  - Use -AllowExistingInstanceInstall only when you intentionally want to rerun install or update steps.
  - Existing config is not rewritten unless you also pass -UpdateExistingConfig.

If you use workshop mods, review the generated script at C:\servers\<InstanceName>\steamcmd\update-conan-mods.txt.

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
- The updater only performs workshop sync when update-conan-mods.txt exists under the instance steamcmd folder.
- Workshop sync copies .pak files into ConanSandbox\Mods and will regenerate modlist.txt when DedicatedServerLauncherModList is present in ServerSettings.ini.
- These scripts intentionally keep server install paths instance-specific so multiple Conan Exiles instances can coexist on the same host.