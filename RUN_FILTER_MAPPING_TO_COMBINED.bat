@echo off
cd /d "%~dp0"
python filter_mapping_to_combined.py
if errorlevel 1 pause
exit /b %errorlevel%
