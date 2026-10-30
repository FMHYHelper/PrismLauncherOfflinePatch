@echo off
rem Double-click wrapper: turns the optional daily background check off and
rem removes the scheduled task. The helper's copy and the log stay in
rem %LocalAppData%\PrismPatcher and can be deleted by hand.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-patcher.ps1" disable-check %*
pause
