@echo off
title Personal YouTube Subscriptions Hub
echo ========================================================
echo   Menjalankan Personal YouTube Hub di http://localhost:8000
echo ========================================================
where.exe adb >nul 2>&1
if not errorlevel 1 adb -d reverse tcp:8000 tcp:8000 >nul 2>&1
start "" "http://localhost:8000"
cd /d %~dp0backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000
