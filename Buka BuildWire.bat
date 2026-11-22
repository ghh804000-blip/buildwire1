@echo off
rem Membuka build web eksperimental BuildWire di browser (build utama: Windows desktop).
rem Tutup jendela ini untuk menghentikan server lokal.
cd /d "%~dp0build\web"
if errorlevel 1 (
  echo Folder build\web tidak ditemukan. Jalankan: flutter build web --no-web-resources-cdn
  echo Catatan: build resmi yang dipelihara adalah Windows desktop (flutter build windows --release).
  pause
  exit /b 1
)
where python >nul 2>&1
if errorlevel 1 (
  echo Python tidak ditemukan di PATH.
  pause
  exit /b 1
)
start "" /b cmd /c "timeout /t 2 /nobreak >nul && start http://127.0.0.1:8765/"
python -m http.server 8765 --bind 127.0.0.1
