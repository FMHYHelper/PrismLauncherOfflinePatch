@echo off
rem Double-click wrapper: interactive update of the patched Prism Launcher.
rem The window stays open at the end so you can read the result.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-patcher.ps1" apply %*
pause
