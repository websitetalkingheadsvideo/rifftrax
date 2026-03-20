@echo off
setlocal EnableExtensions
if /i not "%~1"=="STAYOPEN" (cmd /k call "%~f0" STAYOPEN & exit /b 0)

set "SCRIPT_DIR=%~dp0"
if not "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR%\"
pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: Cannot open script folder.
  pause
  exit /b 3
)
set "ROOT=%CD%.\Combined"
set "MAP=%SCRIPT_DIR%combined_rename_map.csv"

set "PS_EXE=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh"

echo Root: %ROOT%
echo Map:  %MAP%
echo.
"%PS_EXE%" -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%rename_from_map.ps1" -RootPath "%ROOT%" -MapPath "%MAP%" -Mode DryRun -ColumnSeparator Csv

popd >nul 2>&1
echo.
echo Log next to map: rename_from_map.log
echo If plan looks right, run RUN_RENAME_FROM_MAP_APPLY.bat
exit /b 0
