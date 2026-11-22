@echo off
rem drivelog.cmd - Git Bash 를 찾아 drivelog.sh 를 실행한다.
rem   drivelog.cmd status --profile ccnc
rem   drivelog.cmd upload --profile ccnc

setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo Git Bash 를 찾을 수 없다. Git for Windows 설치를 확인할 것.
  exit /b 1
)
"%BASH%" "%~dp0drivelog.sh" %*
