@echo off
setlocal
cd /d "%~dp0"
REM Optional arg: mapped drive root so CSV paths match ReNamer's Files pane, e.g. Z:\Rifftrax
if "%~1"=="" (
  python "%~dp0filter_mapping_rest_of_repo.py"
) else (
  python "%~dp0filter_mapping_rest_of_repo.py" --repo-root "%~1"
)
if errorlevel 1 exit /b 1
endlocal
