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

REM -NoPrettySpaces: strip 1080p/Rifftrax/codecs only; do NOT insert spaces (title/year/CamelCase).
"%PS_EXE%" -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%cleanup_combined_filenames.ps1" -DoIt -NoPrettySpaces
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
echo Verify file: "%SCRIPT_DIR%cleanup_combined_verify.txt"

REM No manual CLI work: generate a quick “any junk patterns still present?” file.
set "VERIFY=%SCRIPT_DIR%cleanup_combined_verify.txt"
"%PS_EXE%" -NoProfile -Command ^
  "$root='\\amber\Rifftrax\Combined'; " ^
  "$rx=[regex]'(?i)(1080\s*p|1080p|6\s*ch|2\s*ch|v\s*2|x265|HEVC)'; " ^
  "$hits=Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $rx.IsMatch($_.Name) }; " ^
  "'' | Out-File -LiteralPath '%VERIFY%' -Encoding UTF8; " ^
  "'TargetRoot=' + $root | Out-File -LiteralPath '%VERIFY%' -Encoding UTF8 -Append; " ^
  "('JunkPatternHits=' + $hits.Count) | Out-File -LiteralPath '%VERIFY%' -Encoding UTF8 -Append; " ^
  "$hits | Select-Object -First 200 FullName | ForEach-Object { $_.FullName } | Out-File -LiteralPath '%VERIFY%' -Encoding UTF8 -Append"

start "" notepad "%SCRIPT_DIR%cleanup_combined_filenames.log"
start "" notepad "%SCRIPT_DIR%cleanup_combined_report.txt"
start "" notepad "%SCRIPT_DIR%cleanup_combined_verify.txt"
echo Type EXIT or close this window when finished.
exit /b %EXIT_CODE%
