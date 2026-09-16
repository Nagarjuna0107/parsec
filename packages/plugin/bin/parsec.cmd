@echo off
rem Platform shim: run the win-x64 parsec binary. Same lookup order as the sh
rem shim beside it: bundled bin\win-x64\parsec.exe (dev builds, the release
rem zip), then %USERPROFILE%\.parsec\bin\parsec.exe (install.ps1 / setup.exe),
rem else bootstrap.ps1 fetches this plugin's version from GitHub Releases. At
rem SessionStart bootstrap.ps1 also upgrades an installed binary older than
rem the plugin. stdin (the hook payload) is kept away from PowerShell.
setlocal
set "BIN=%~dp0win-x64\parsec.exe"
if exist "%BIN%" goto run
set "HOMEDIR=%HOME%"
if "%HOMEDIR%"=="" set "HOMEDIR=%USERPROFILE%"
set "BIN=%HOMEDIR%\.parsec\bin\parsec.exe"
set "REFRESH=0"
if "%~1"=="hook" if "%~2"=="SessionStart" set "REFRESH=1"
if not exist "%BIN%" set "REFRESH=1"
if "%REFRESH%"=="1" powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" -PluginRoot "%~dp0.." -Dest "%BIN%" < nul
if not exist "%BIN%" exit /b 1
:run
"%BIN%" %*
