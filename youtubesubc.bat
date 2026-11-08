@echo off
title Personal YouTube Subscriptions Hub
echo ========================================================
echo   Menjalankan Personal YouTube Hub di http://localhost:8000
echo ========================================================
start "" "http://localhost:8000"
cd /d %~dp0backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000
