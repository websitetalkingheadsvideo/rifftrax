@echo off
setlocal
cd /d "%~dp0"
python "%~dp0filter_mapping_rest_of_repo.py"
if errorlevel 1 exit /b 1
endlocal
