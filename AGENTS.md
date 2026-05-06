# AutoConan Agent Notes

These rules capture validated behavior from this environment and should be treated as project defaults unless the user explicitly asks otherwise.

## Scope
- Applies to scripts in this repository, especially install and task automation.
- Primary files: install_server.ps1, set_task.ps1, update_modules.ps1.

## Scheduled Task Rules
- Keep the machine reboot task shared as a single task name: NightlyRestart.
- Do not create multiple per-instance reboot tasks unless the user explicitly asks.
- Keep update and startup tasks instance-specific to avoid collisions:
  - ConanNightlyUpdate-<instance>
  - ConanStartOnBoot-<instance>
- set_task.ps1 must pass BasePath and InstanceName through to update_modules.ps1.

## Multi-instance Rules
- Support multiple instances via BasePath + InstanceName in scripts.
- Do not hardcode Conan Exiles paths in task/update logic.
- Require InstanceName explicitly in script parameters (no default value).
- Per-instance layout must be:
  - <BasePath>\<InstanceName>\steamcmd
  - <BasePath>\<InstanceName>\gamefiles

## Server Configuration Conventions
- install_server.ps1 should support configuring these at install-time when provided:
  - ServerName
  - ServerPassword
- install_server.ps1 must declare setup inputs as mandatory parameters so PowerShell prompts automatically when values are missing.
- Required setup parameters are: ServerName and ServerPassword.
- ServerPassword may be left blank when the user wants an open server; do not reject empty input at parameter binding.
- If Engine.ini or ServerSettings.ini is missing, bootstrap once to generate them, then write settings.
- install_server.ps1 and update_modules.ps1 should install/update the server into <BasePath>\<InstanceName>\gamefiles.
- SteamCMD and workshop assets should live under <BasePath>\<InstanceName>\steamcmd.
- After install, output the active ServerName and ServerPassword values from Engine.ini.

## Safe Runtime Edit Rules
- Stop the Conan server process before modifying config files.
- Restart the server after config edits.
- Stop the Conan server process before moving game files between layout locations.
- Verify both:
  - Config file values
  - Running server process

## Practical Defaults
- Keep changes minimal and avoid altering unrelated server settings.
- Preserve the Windrose method here: per-instance folders, self-elevating admin scripts, instance-scoped process matching, nightly update task, shared reboot task, and start-on-boot task.