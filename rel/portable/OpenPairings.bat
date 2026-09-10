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
rem Erlang distribution off. A release does not do this by default: it starts
rem `epmd` on 0.0.0.0:4369 and a node listener on 0.0.0.0:<ephemeral>, both on
rem every interface. Measured on this release, not assumed - the web port was
rem already correctly pinned to loopback and these two were not.
rem
rem What makes it more than untidy is the cookie. `releases\COOKIE` ships
rem inside the download, so it is the same on every copy anybody installs, and
rem a reachable node plus a known cookie is a stranger running code on this
rem machine. On club or hotel wifi that is a real door, not a theoretical one.
rem Nothing here wants distribution: one person, one computer, and stopping is
rem closing this window rather than a remote call. Turning it off also removes
rem a Windows Firewall prompt on first run.
rem
rem Overridable, unlike OpenPairings.exe which forces it. This is the
rem diagnostic launcher - the one you run when something is wrong - so
rem `set RELEASE_DISTRIBUTION=sname` before starting it is the way to get a
rem node that `bin\pairings_engine_portable.bat remote` can attach to. That
rem is a thing somebody chooses, never a thing that happens by default.
if "%RELEASE_DISTRIBUTION%"=="" set RELEASE_DISTRIBUTION=none
echo Starting OpenPairings on http://localhost:%PORT%
echo Close this window to stop it.
echo.
"%~dp0bin\pairings_engine_portable.bat" start
endlocal
