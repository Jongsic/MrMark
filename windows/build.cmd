@echo off
rem Builds MrMark for Windows: windows\bin\MrMark.exe (+ tests.exe with "test")
rem Requires the MSVC Build Tools:
rem   winget install Microsoft.VisualStudio.2022.BuildTools --override ^
rem     "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
setlocal
rem Locate the MSVC environment: vswhere finds any VS edition (Build Tools
rem locally, Enterprise on GitHub runners); fall back to the Build Tools path.
set "VSDEV="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDEV=%%i\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VSDEV set "VSDEV=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VSDEV%" (
  echo MSVC Build Tools not found; see the comment at the top of this script.
  exit /b 1
)
call "%VSDEV%" >nul 2>nul

set ROOT=%~dp0
set OUT=%ROOT%bin
if not exist "%OUT%" mkdir "%OUT%"

set CFLAGS=/nologo /std:c++17 /utf-8 /O2 /W3 /EHsc /DUNICODE /D_UNICODE /MT

rc /nologo /fo "%OUT%\app.res" "%ROOT%res\app.rc" || exit /b 1
cl %CFLAGS% ^
  "%ROOT%src\main.cpp" "%ROOT%src\parser.cpp" "%ROOT%src\document.cpp" ^
  "%ROOT%src\formatting.cpp" "%ROOT%src\styler.cpp" "%OUT%\app.res" ^
  /Fe"%OUT%\MrMark.exe" /Fo"%OUT%\\" ^
  /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib ^
  comdlg32.lib comctl32.lib dwmapi.lib shlwapi.lib uxtheme.lib advapi32.lib ^
  windowscodecs.lib || exit /b 1
echo Built %OUT%\MrMark.exe

if "%1"=="test" (
  cl %CFLAGS% ^
    "%ROOT%tests\tests.cpp" "%ROOT%src\parser.cpp" "%ROOT%src\document.cpp" ^
    "%ROOT%src\formatting.cpp" "%ROOT%src\styler.cpp" ^
    /Fe"%OUT%\tests.exe" /Fo"%OUT%\\" /I"%ROOT%src" ^
    /link /SUBSYSTEM:CONSOLE || exit /b 1
  "%OUT%\tests.exe" || exit /b 1
)
