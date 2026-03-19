@echo off
setlocal EnableExtensions
REM Plex rename: run from this folder (Rifftrax root). Double-click to run.

set "SCRIPT_DIR=%~dp0"
if not "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR%\"
set "PS_SCRIPT=%SCRIPT_DIR%plex_rename.ps1"

if not exist "%PS_SCRIPT%" (
  echo ERROR: Script not found: "%PS_SCRIPT%"
  exit /b 2
)

pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: Failed to switch to script directory: "%SCRIPT_DIR%"
  exit /b 3
)

REM Avoid cmd.exe quoting bug when path ends with backslash.
set "ROOT=%CD%."

set "PS_EXE=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh"

"%PS_EXE%" -ExecutionPolicy Bypass -NoProfile -File "%PS_SCRIPT%" -RootPath "%ROOT%" -DoIt
set "EXIT_CODE=%ERRORLEVEL%"

popd >nul 2>&1
echo.
echo Log: %ROOT%\plex_rename_log.csv
if not "%EXIT_CODE%"=="0" (
  echo ERROR: plex_rename.ps1 failed with exit code %EXIT_CODE%.
)
pause
exit /b %EXIT_CODE%
