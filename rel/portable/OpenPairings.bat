@echo off
rem Start OpenPairings on this machine, for one person, with no setup.
rem
rem Sets OPENPAIRINGS_LOCAL because a plain release cannot work it out for
rem itself: the standalone binary detects `__BURRITO`, and this is precisely
rem the build that is not one. Everything else - the database location, the
rem secret, the fact that there is no login - follows from that one variable.
setlocal
set OPENPAIRINGS_LOCAL=1
if "%PORT%"=="" set PORT=4000
echo Starting OpenPairings on http://localhost:%PORT%
echo Close this window to stop it.
echo.
"%~dp0bin\pairings_engine_portable.bat" start
endlocal
