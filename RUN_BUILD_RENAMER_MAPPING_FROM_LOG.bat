@echo off
setlocal
cd /d "%~dp0"
python "%~dp0build_renamer_mapping_from_cleanup_log.py"
if errorlevel 1 exit /b 1
endlocal
