@echo off
setlocal EnableExtensions
REM Strips 1080p / Rifftrax / 6 ch / v 2 junk from video names under Combined.
REM Double-click to run. No PowerShell knowledge needed.

REM Re-launch under cmd /k so the window stays open (double-click often closes too fast to read).
if /i not "%~1"=="STAYOPEN" (
  cmd /k call "%~f0" STAYOPEN
  exit /b 0
)

set "SCRIPT_DIR=%~dp0"
if not "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR%\"

REM CMD cannot use UNC as current directory; pushd maps a temp drive (e.g. Z:) and cds there.
pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: Cannot open script folder. Map a drive letter to the share or run from a mapped path.
  pause
  exit /b 3
)

set "PS_EXE=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh"

"%PS_EXE%" -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%cleanup_combined_filenames.ps1" -DoIt
set "EXIT_CODE=%ERRORLEVEL%"

popd >nul 2>&1

echo.
if not "%EXIT_CODE%"=="0" (
  echo ERROR: exit code %EXIT_CODE%.
) else (
  echo Done. Scroll up to read RENAMED / CONFLICT / LOCKED / FAIL lines.
  echo FAIL = real error text — also in: "%SCRIPT_DIR%cleanup_combined_filenames.log"
  echo LOCKED = sharing violation — quit Plex / Explorer preview, then run again.
)
echo.
echo Log file: "%SCRIPT_DIR%cleanup_combined_filenames.log"
echo Report:   "%SCRIPT_DIR%cleanup_combined_report.txt"  (double-click opens in Notepad)
echo Type EXIT or close this window when finished.
exit /b %EXIT_CODE%
