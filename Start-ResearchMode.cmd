@echo off
setlocal
chcp 65001 >nul
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ResearchMode.ps1"
) else (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ResearchMode.ps1"
)
if errorlevel 1 pause
