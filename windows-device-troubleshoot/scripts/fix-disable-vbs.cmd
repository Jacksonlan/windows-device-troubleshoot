@echo off
rem Disable VBS / WHQL driver enforcement to unblock a driver blocked with code 48.
rem ASCII only on purpose: UTF-8 Chinese text breaks cmd parsing.
rem Self-elevates. Backs up registry before change. Reversible via undo-vbs.cmd.

setlocal
title Disable VBS - fix driver blocked (code 48)

net session >nul 2>&1
if errorlevel 1 goto ELEV

cls
echo ==================================================
echo   Disable VBS / WHQL driver enforcement
echo   Target: device blocked with code 48
echo ==================================================
echo.
echo   WARNING: if BitLocker is ON for C:, changing boot
echo   configuration may ask for the recovery key.
echo   Verify you have the key before continuing.
echo.
pause

echo.
echo [1/4] Backup registry to Desktop
reg export "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" "%USERPROFILE%\Desktop\vbs-backup.reg" /y >nul 2>&1
echo       saved: %USERPROFILE%\Desktop\vbs-backup.reg

echo.
echo [2/4] Disable VBS and WHQL enforcement
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v RequireMicrosoftSignedBootChain /t REG_DWORD /d 0 /f >nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CI\Config" /v VulnerableDriverBlocklistEnable /t REG_DWORD /d 0 /f >nul
bcdedit /set hypervisorlaunchtype off >nul 2>&1
echo       done

echo.
echo [3/4] Rescan hardware
pnputil /scan-devices >nul 2>&1
echo       done

echo.
echo [4/4] Verify
reg query "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity

echo.
echo ==================================================
echo   Done. REBOOT now (restart, not shutdown).
echo   After reboot check Device Manager.
echo   Still code 48? run undo-vbs.cmd
echo ==================================================
echo.
pause
exit /b

:ELEV
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
