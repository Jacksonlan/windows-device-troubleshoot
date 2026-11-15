@echo off
rem Restore VBS settings changed by fix-disable-vbs.cmd. ASCII only.

setlocal
title Restore VBS settings

net session >nul 2>&1
if errorlevel 1 goto ELEV

cls
echo Restoring VBS settings...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v RequireMicrosoftSignedBootChain /t REG_DWORD /d 1 /f >nul
bcdedit /set hypervisorlaunchtype auto >nul 2>&1
echo Done. Takes effect after reboot.
echo.
pause
exit /b

:ELEV
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
