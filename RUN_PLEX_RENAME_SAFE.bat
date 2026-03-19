@echo off
REM Same as RUN_PLEX_RENAME.bat; alternate filename in case Explorer hides one.
pushd "%~dp0" >nul 2>&1
REM Avoid cmd.exe quoting bug when path ends with backslash.
set "ROOT=%CD%."
powershell -ExecutionPolicy Bypass -NoProfile -File "%CD%\plex_rename.ps1" -RootPath "%ROOT%" -DoIt
popd >nul 2>&1
echo.
echo Log: %ROOT%\plex_rename_log.csv
pause
