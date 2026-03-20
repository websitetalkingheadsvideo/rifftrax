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
set "OUT=%SCRIPT_DIR%combined_rename_map.csv"

set "PS_EXE=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh"

"%PS_EXE%" -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%export_combined_rename_template.ps1" -RootPath "%ROOT%" -OutMapPath "%OUT%"

popd >nul 2>&1
echo Wrote combined_rename_map.csv  OldRel,NewRel  — edit NewRel or use ReNamer. See COMBINED_RENAME_WORKFLOW.txt
echo Then RUN_RENAME_FROM_MAP_DRYRUN.bat
exit /b 0
