@echo off
rem Guided setup of pvg-metal-vulkan on Windows: double-click this file (see docs\windows.md).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-windows.ps1" %*
if errorlevel 1 pause
