@echo off
rem Double-click wrapper: turns the optional daily background check on.
rem It registers a Windows scheduled task (per-user, no admin needed) and
rem copies the helper to a stable folder. Remove it with
rem update-check-disable.cmd at any time.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-patcher.ps1" enable-check %*
pause
