/*
 * OpenPairings.exe - the double-clickable front door of the portable release.
 *
 * Built by build_launcher.ps1 with `zig cc`; see docs/binaries.md. It lives at
 * the root of the portable release, beside OpenPairings.bat, and it is what
 * Velopack's --mainExe points at.
 *
 * ## Why this exists at all
 *
 * Two reasons, and the second is the one that made it mandatory.
 *
 * 1. OpenPairings.bat works, and it works by showing a console window full of
 *    BEAM output. The audience is Belgian club arbiters, many of whom are not
 *    computer people; a black window scrolling Erlang crash reports is what
 *    makes software look broken to them even when it is fine. This starts the
 *    same release with no window at all except a small status one.
 *
 * 2. Velopack's -e/--mainExe takes a FILE NAME and requires that executable to
 *    exist in the package root. A .bat cannot be it. Without this file there is
 *    no installer at all.
 *
 * ## Why C compiled by Zig, and not .NET
 *
 * .NET framework-dependent needs a runtime on the arbiter's machine, which is
 * the one thing the portable release promises there is not. .NET
 * self-contained adds ~60 MB to a 155 MB payload. Zig is already this
 * project's documented build dependency (Burrito needs it), it cross-compiles
 * from any host, and it produces ~100 KB with nothing to install. C rather
 * than Zig-the-language because Zig's standard library changes shape between
 * releases and CI pins Zig 0.15.2 for Burrito while a developer machine may
 * have anything newer - `zig cc` and windows.h are stable across all of them.
 *
 * ## The four things it has to get right
 *
 * - **Resolve everything from its own path.** A Start Menu shortcut launches
 *   with an arbitrary working directory, so `bin\...` relative to the cwd
 *   finds nothing. GetModuleFileNameW is the only honest answer.
 * - **Wait for the port before opening a browser.** Opening first and hoping
 *   shows the arbiter a connection error, and an arbiter who sees a browser
 *   error concludes the program is broken. So: poll, then open.
 * - **No console window.** The GUI subsystem plus CREATE_NO_WINDOW on the
 *   child; the whole cmd -> elixir.bat -> erl.exe chain inherits the invisible
 *   console.
 * - **No orphaned BEAM.** A job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
 *   holds the child tree, so the server dies with this process even if this
 *   process is killed from Task Manager rather than closed politely.
 *
 * ## What "closing" means, which is the interesting one
 *
 * Removing the console removes the stop button: the console window WAS how you
 * stopped OpenPairings ("Close this window to stop it", says the .bat). A tray
 * icon is out of scope and would be worse anyway - a tray icon is where things
 * go to be forgotten about, and this one holds an open database.
 *
 * So this shows a small window that says what is happening and says, in words,
 * that closing it stops the program. Closing it terminates the job, which
 * takes the whole BEAM tree with it. The server's lifetime is exactly the
 * window's lifetime, which is a rule an arbiter can hold in their head.
 *
 * The kill is abrupt rather than a graceful `bin\... stop`, deliberately:
 * `stop` is an RPC that boots a second BEAM, needs Erlang distribution and
 * epmd, and takes seconds. SQLite is crash-safe by construction, every write
 * the app makes is a committed transaction, and closing the console window
 * today is exactly as abrupt. Trading crash-safety we already have for a
 * multi-second shutdown and a firewall dependency is a bad trade.
 *
 * A named mutex makes a second double-click open a browser tab at the running
 * instance rather than start a second server that would fail to bind the port.
 *
 * ## In-app updates ("Install and restart")
 *
 * Only THIS process can apply a Velopack update - see
 * `PairingsEngine.Updates.InstallKind`'s moduledoc for why the app itself
 * cannot: it is a *child* of this launcher's job object, not the process
 * Velopack's apply-and-restart is designed around. So the arbiter's click,
 * in the browser, has to cross that boundary, and it crosses it the same
 * way this file already watches for a start that failed: by watching the
 * child process exit.
 *
 * The app, on confirmation, shuts itself down cleanly
 * (`PairingsEngine.Updates.request_install_and_restart/0` - closes every
 * connection, including the database, the same way an ordinary graceful
 * stop does) with the dedicated exit code `OP_UPDATE_EXIT_CODE`. Nothing
 * else in this application ever exits on its own, so seeing the child die
 * with exactly that code, once the server was already running, is an
 * unambiguous signal - not a crash, not the window being closed (that path
 * kills the job instead of waiting for a clean exit; see `stop_server`
 * below).
 *
 * From there this file drives Velopack's own C ABI, `velopack_libc.dll` -
 * loaded with `LoadLibrary`/`GetProcAddress`, and ONLY at this moment, never
 * at ordinary startup. Two reasons: an arbiter who never touches the button
 * should never pay for it (no extra DLL load, no extra antivirus scan, on
 * every single launch), and if the DLL is missing or blocked - antivirus
 * quarantine is the expected case - that must be invisible until the one
 * moment it matters, never a reason the app fails to start. `load_velopack`
 * below is the only place this DLL is touched, and it is only ever called
 * from `apply_update_and_restart`.
 *
 * `apply_update_and_restart` cannot leave an arbiter without a running
 * program - that is the one hard requirement this feature was built under.
 * So every failure path (the DLL is missing, no update is out, the download
 * fails, the apply fails) falls through to the exact same thing: say so in
 * this window, then `start_server()` again on the version already on disk.
 * Only the success path is different, and even that does not restart
 * anything itself - it hands off to Velopack's own `Update.exe`, which
 * waits for this process to exit and then relaunches `OpenPairings.exe`
 * fresh, running this file's `WinMain` from the top like any other
 * double-click.
 *
 * The install directory (`%LOCALAPPDATA%\OpenPairingsApp`) and the data
 * directory (`%LOCALAPPDATA%\OpenPairings`, where `openpairings.db` lives)
 * are different folders on purpose - see `rel/windows/build_installer.ps1`'s
 * `.NOTES` - so nothing about applying an update ever touches the database
 * directly; closing it cleanly before the swap is the app's job, above.
 */

/* UNICODE so the MAKEINTRESOURCE-style constants (IDC_ARROW and friends)
 * expand to their wide form; every API call below is explicitly the W one.
 * The version floor is guarded because `zig cc` already predefines a newer
 * one - this is for any other compiler that does not. */
#define UNICODE
#define _UNICODE
#ifndef WINVER
#define WINVER 0x0601
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <commctrl.h>
/* stdint/stdbool: only for the velopack_libc call shapes below (its real
 * header, Velopack.h, is itself generated against these same fixed-width
 * types - see the "Velopack (velopack_libc.dll)" section) - nothing else in
 * this file needed either. */
#include <stdint.h>
#include <stdbool.h>

/* Control and message ids. WM_APP+n is the documented private range for a
 * window to talk to itself; the waiter thread uses it to report across to the
 * UI thread rather than touching controls from off-thread. */
#define IDC_LOGO 101
#define IDC_STATUS 102
#define IDC_URL 103
#define IDC_HINT 104
#define IDC_OPEN 105
#define IDC_STOP 106
#define IDC_VERSION 107

#define WM_APP_READY (WM_APP + 1)
#define WM_APP_SLOW (WM_APP + 2)
#define WM_APP_FAILED (WM_APP + 3)
/* Posted by `waiter` when the child exits AFTER the server was already
 * running - never during startup, which WM_APP_FAILED already covers. See
 * the "In-app updates" section of this file's header comment. wParam is the
 * child's own exit code from GetExitCodeProcess. */
#define WM_APP_CHILD_EXITED (WM_APP + 4)

#define FAIL_EXITED 1
#define FAIL_TIMEOUT 2

/* The exit code `PairingsEngine.Updates.request_install_and_restart/0`
 * halts the BEAM with once an arbiter confirms "Install and restart" - see
 * that function's own comment for why `System.stop/1`, not `halt/1`, is
 * what gets here, and this file's "In-app updates" header section for the
 * rest of the path. Arbitrary; chosen only to not collide with 0 (this
 * process exiting because nothing went wrong) or 1 (Erlang's usual crash
 * code). Cross-referenced by comment on both sides rather than shared as a
 * config value - a native launcher compiled separately cannot read this
 * application's config at compile time, so a magic number two places have
 * to agree on is exactly what the comment is for. */
#define OP_UPDATE_EXIT_CODE 90

/* Two minutes, which is long for a start that normally takes five seconds. It
 * is sized for the cold first run on a slow laptop: the BEAM boots, the
 * migrations run against a database that does not exist yet, and an antivirus
 * scanner reads 155 MB of freshly written DLLs while that happens. Waiting too
 * long only costs a slow-start hint on screen; giving up too early tells an
 * arbiter their software is broken when it was about to work. The far more
 * common failure - a start that already died - is caught in a second by
 * watching the child, so this bound is rarely what reports anything. */
#define START_TIMEOUT_MS 120000
#define SLOW_HINT_MS 20000
#define POLL_INTERVAL_MS 250

#define PATH_MAX_W 1024

static HINSTANCE g_inst;
static HWND g_wnd;
static HWND g_status, g_hint, g_version;
static HFONT g_font, g_title_font;
/* "OpenPairings 0.59.0 · Ainalrami 0.26.0" and "OpenPairings 0.59.0" - see
 * read_versions(). Empty when nothing could be read. */
static WCHAR g_versions[96];
static WCHAR g_title[48] = L"OpenPairings";
static HANDLE g_job, g_child, g_log_handle;
static int g_dpi = 96;
static int g_port = 4000;
static WCHAR g_url[64];
static WCHAR g_root[PATH_MAX_W];
static WCHAR g_log_path[PATH_MAX_W];

/* Design units are 96-dpi pixels; everything on screen goes through this. */
#define S(x) MulDiv((x), g_dpi, 96)

static void fatal(const WCHAR *text)
{
    MessageBoxW(NULL, text, L"OpenPairings", MB_OK | MB_ICONERROR);
    ExitProcess(1);
}

static void open_browser(void)
{
    ShellExecuteW(NULL, L"open", g_url, NULL, NULL, SW_SHOWNORMAL);
}

/* GetModuleFileNameW, not GetCurrentDirectoryW: a Start Menu or Desktop
 * shortcut runs this with whatever working directory Explorer felt like, and
 * Velopack's own stub launches it from a directory above the release. The
 * executable's own location is the only thing that is reliably next to `bin`. */
static void resolve_root(void)
{
    DWORD n = GetModuleFileNameW(NULL, g_root, PATH_MAX_W);
    if (n == 0 || n >= PATH_MAX_W)
        fatal(L"OpenPairings could not work out where it is installed.");

    while (n > 0 && g_root[n - 1] != L'\\')
        n--;
    g_root[n] = 0;
}

static void join(WCHAR *out, const WCHAR *dir, const WCHAR *tail)
{
    lstrcpynW(out, dir, PATH_MAX_W);
    lstrcpynW(out + lstrlenW(out), tail, PATH_MAX_W - lstrlenW(out));
}

/* Copies a version string (digits, dots and the odd letter - always ASCII)
 * until the first character that cannot be part of one. */
static void copy_version(WCHAR *out, int out_len, const char *in)
{
    int i = 0;
    while (i < out_len - 1 && in[i] && in[i] != ' ' && in[i] != '\r' && in[i] != '\n' &&
           in[i] != '\t')
    {
        out[i] = (WCHAR)(unsigned char)in[i];
        i++;
    }
    out[i] = 0;
}

/* Which OpenPairings and which pairing engine this window is running, read
 * from the release on disk rather than asked of the server, so the line is
 * there from the moment the window opens - including when the server never
 * answers, which is exactly when somebody wants to quote a version.
 *
 *   releases\start_erl.data   "<erts version> <release version>", written by
 *                             `mix release`; the release version is mix.exs's
 *   lib\ainalrami-<version>\  the engine's own application directory
 *
 * Either one missing just drops out of the line; neither leaves it blank. */
static void read_versions(void)
{
    WCHAR path[PATH_MAX_W], app[32] = L"", engine[32] = L"";
    char buf[128];
    DWORD got = 0;
    HANDLE file, find;
    WIN32_FIND_DATAW found;

    join(path, g_root, L"releases\\start_erl.data");
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        if (ReadFile(file, buf, sizeof buf - 1, &got, NULL)) {
            char *p = buf;
            buf[got] = 0;
            while (*p && *p != ' ')
                p++;
            while (*p == ' ')
                p++;
            copy_version(app, 32, p);
        }
        CloseHandle(file);
    }

    join(path, g_root, L"lib\\ainalrami-*");
    find = FindFirstFileW(path, &found);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                lstrcpynW(engine, found.cFileName + lstrlenW(L"ainalrami-"), 32);
                break;
            }
        } while (FindNextFileW(find, &found));
        FindClose(find);
    }

    if (app[0] && engine[0])
        wsprintfW(g_versions, L"OpenPairings %s \x00B7 Ainalrami %s", app, engine);
    else if (app[0])
        wsprintfW(g_versions, L"OpenPairings %s", app);
    else if (engine[0])
        wsprintfW(g_versions, L"Ainalrami %s", engine);

    if (app[0])
        wsprintfW(g_title, L"OpenPairings %s", app);
}

static int read_port(void)
{
    WCHAR buf[16];
    DWORD n = GetEnvironmentVariableW(L"PORT", buf, 16);
    int value = 0;
    DWORD i;

    /* Same contract as OpenPairings.bat: PORT wins if it is set, 4000
     * otherwise. Anything unparseable falls back rather than failing - a typo
     * in an environment variable should not stop a tournament. */
    if (n == 0 || n >= 16)
        return 4000;

    for (i = 0; i < n; i++) {
        if (buf[i] < L'0' || buf[i] > L'9')
            return 4000;
        value = value * 10 + (buf[i] - L'0');
        if (value > 65535)
            return 4000;
    }

    return value > 0 ? value : 4000;
}

/* Where the child's stdout and stderr go. Next to the database, because that
 * is where an arbiter has already been told their OpenPairings files live, and
 * because the release directory itself may be read-only. */
static void resolve_log_path(void)
{
    WCHAR dir[PATH_MAX_W], local[PATH_MAX_W];
    DWORD n;

    /* GetEnvironmentVariableW returns the REQUIRED size, and writes nothing,
     * when the value does not fit - so "non-zero" is not the same as "dir now
     * holds a path". Both reads are bounded for that reason. */
    n = GetEnvironmentVariableW(L"OPENPAIRINGS_DATA_DIR", dir, PATH_MAX_W);

    if (n == 0 || n >= PATH_MAX_W) {
        n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, PATH_MAX_W);

        if (n > 0 && n < PATH_MAX_W)
            join(dir, local, L"\\OpenPairings");
        else if (GetTempPathW(PATH_MAX_W, dir) == 0)
            lstrcpynW(dir, g_root, PATH_MAX_W);
    }

    CreateDirectoryW(dir, NULL);
    join(g_log_path, dir, L"\\launcher.log");
}

/* A plain connect() to loopback. Before Bandit binds, this is refused
 * immediately; after it binds, it succeeds. That is precisely the question
 * "is the app listening yet", with no HTTP request to get wrong. */
static int port_open(void)
{
    SOCKET s;
    struct sockaddr_in addr;
    int ok;

    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET)
        return 0;

    ZeroMemory(&addr, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)g_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    ok = connect(s, (struct sockaddr *)&addr, sizeof addr) == 0;
    closesocket(s);
    return ok;
}

static DWORD WINAPI waiter(LPVOID unused)
{
    DWORD started = GetTickCount();
    int told_slow = 0;

    (void)unused;

    for (;;) {
        if (port_open()) {
            DWORD code;

            PostMessageW(g_wnd, WM_APP_READY, 0, 0);

            /* Still here, not returning: once the server is up, this same
             * thread's job becomes watching for it to go back down again -
             * see WM_APP_CHILD_EXITED and the "In-app updates" section of
             * this file's header comment. There is no timeout on this wait;
             * an arbiter's tournament can run for hours, and this thread
             * costs nothing while it is blocked. */
            WaitForSingleObject(g_child, INFINITE);
            code = 0;
            GetExitCodeProcess(g_child, &code);
            PostMessageW(g_wnd, WM_APP_CHILD_EXITED, code, 0);
            return 0;
        }

        /* The usual failure is not a slow start, it is a start that already
         * died - a port in use, a corrupt database, a missing DLL. Watching
         * the child means that is reported in a second instead of after the
         * full timeout. */
        if (WaitForSingleObject(g_child, 0) == WAIT_OBJECT_0) {
            PostMessageW(g_wnd, WM_APP_FAILED, FAIL_EXITED, 0);
            return 0;
        }

        {
            DWORD elapsed = GetTickCount() - started;

            if (!told_slow && elapsed > SLOW_HINT_MS) {
                told_slow = 1;
                PostMessageW(g_wnd, WM_APP_SLOW, 0, 0);
            }

            if (elapsed > START_TIMEOUT_MS) {
                PostMessageW(g_wnd, WM_APP_FAILED, FAIL_TIMEOUT, 0);
                return 0;
            }
        }

        Sleep(POLL_INTERVAL_MS);
    }
}

static void start_server(void)
{
    WCHAR bat[PATH_MAX_W], comspec[PATH_MAX_W], cmdline[PATH_MAX_W * 3];
    WCHAR port_text[16];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa;
    HANDLE nul;

    join(bat, g_root, L"bin\\pairings_engine_portable.bat");
    if (GetFileAttributesW(bat) == INVALID_FILE_ATTRIBUTES) {
        WCHAR message[PATH_MAX_W + 256];
        wsprintfW(message,
                  L"OpenPairings is incomplete.\n\n"
                  L"This file expected to find the program next to it, at:\n%s\n\n"
                  L"Unzip the whole download and run OpenPairings.exe from inside it, "
                  L"rather than copying the one file out.",
                  bat);
        fatal(message);
    }

    if (GetSystemDirectoryW(comspec, PATH_MAX_W) == 0)
        fatal(L"OpenPairings could not find the Windows system directory.");
    lstrcpynW(comspec + lstrlenW(comspec), L"\\cmd.exe", PATH_MAX_W - lstrlenW(comspec));

    /* /d skips whatever a machine has in the AutoRun registry key - somebody
     * else's shell customisation must not run inside our process tree. /s
     * makes cmd strip exactly the outer pair of quotes, which is what lets the
     * path and the argument keep their own. */
    wsprintfW(cmdline, L"\"%s\" /d /s /c \"\"%s\" start\"", comspec, bat);

    /* The same three variables OpenPairings.bat sets, plus one it does not.
     *
     * OPENPAIRINGS_LOCAL, because a plain release cannot detect local mode for
     * itself - it looks for __BURRITO and this is exactly the build that is
     * not one. Set unconditionally, as both existing launchers do.
     *
     * OPENPAIRINGS_NO_BROWSER, because the app's own BrowserLauncher would
     * otherwise open a second tab the moment the endpoint binds. Worse, it
     * opens it with `cmd /c start`, and a cmd spawned from a process whose
     * console is hidden flashes a black window on screen - the exact thing
     * this executable exists to remove. Browser-opening is this launcher's job
     * now, and it is the one that knows the port really answered. */
    SetEnvironmentVariableW(L"OPENPAIRINGS_LOCAL", L"1");
    SetEnvironmentVariableW(L"OPENPAIRINGS_NO_BROWSER", L"1");
    wsprintfW(port_text, L"%d", g_port);
    SetEnvironmentVariableW(L"PORT", port_text);

    /* The one this launcher adds. A release defaults to RELEASE_DISTRIBUTION
     * =sname, which starts epmd on 0.0.0.0:4369 and an Erlang distribution
     * listener on 0.0.0.0:<ephemeral> - measured, not assumed. Nothing here
     * needs either: this is one person on one computer, the web port is pinned
     * to loopback on purpose, and the stop button is a job object rather than
     * an RPC.
     *
     * What it buys, in order: no Windows Firewall prompt on first run, which
     * to a club arbiter is an alarming dialog from a chess program; no listener
     * on every interface for a node whose cookie ships inside the download and
     * is therefore identical on every copy of it; and one fewer process.
     *
     * Set unconditionally here, and that is the difference from the other
     * launchers: OpenPairings.bat, openpairings.sh and the macOS bundle now
     * default to `none` too, but let a pre-set RELEASE_DISTRIBUTION through.
     * This one does not, because it is the front door - the thing an arbiter
     * double-clicks - and an escape hatch on the front door is a hole with a
     * label on it. Somebody who wants a node to attach `remote` or `rpc` to
     * runs `set RELEASE_DISTRIBUTION=sname` and then OpenPairings.bat, which
     * is the diagnostic launcher and is where that belongs.
     *
     * The cost of `none`, stated plainly: `bin\pairings_engine_portable.bat
     * stop|restart|pid` are RPC to a named node, so they have nothing to talk
     * to. Irrelevant here - the stop button is the job object above, and it
     * was already chosen over `stop` for the reasons at the top of this file. */
    SetEnvironmentVariableW(L"RELEASE_DISTRIBUTION", L"none");

    ZeroMemory(&sa, sizeof sa);
    sa.nLength = sizeof sa;
    sa.bInheritHandle = TRUE;

    g_log_handle = CreateFileW(g_log_path, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                      FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);

    if (g_log_handle != INVALID_HANDLE_VALUE) {
        /* One line of context at the top, so a log somebody mails in says
         * which release and which port it came from. The child inherits this
         * handle and its file pointer, so its own output continues after. */
        char header[PATH_MAX_W * 2];
        int len = wsprintfA(header, "OpenPairings launcher: %S start (port %d)\r\n",
                            cmdline, g_port);
        DWORD written;
        WriteFile(g_log_handle, header, (DWORD)len, &written, NULL);
    }

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    /* STARTF_USESTDHANDLES means all three are taken literally, INVALID_HANDLE
     * _VALUE included - a read-only or missing data directory would otherwise
     * turn "no log this run" into "no server this run". NUL is the fallback:
     * losing the diagnosis is bad, losing the program is worse. */
    si.hStdOutput = g_log_handle == INVALID_HANDLE_VALUE ? nul : g_log_handle;
    si.hStdError = si.hStdOutput;

    /* KILL_ON_JOB_CLOSE is the whole anti-orphan mechanism. The handle is
     * closed when this process ends for ANY reason - closed window, End Task,
     * a crash in this file - and the kernel then terminates everything in the
     * job. Nothing here has to remember to clean up, which is the point: a
     * launcher that leaks a server process is only ever one forgotten code
     * path away otherwise. */
    g_job = CreateJobObjectW(NULL, NULL);
    if (g_job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
        ZeroMemory(&limits, sizeof limits);
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &limits,
                                sizeof limits);
    }

    /* CREATE_NO_WINDOW gives the child a console that is never shown; cmd,
     * elixir.bat and erl.exe all inherit it, so the whole chain is silent.
     * CREATE_SUSPENDED closes the race where cmd could spawn a grandchild
     * before we had put it in the job - that grandchild would then outlive us. */
    if (!CreateProcessW(comspec, cmdline, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, g_root, &si, &pi))
        fatal(L"OpenPairings could not start its server process.");

    if (g_job)
        AssignProcessToJobObject(g_job, pi.hProcess);

    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    g_child = pi.hProcess;

    if (nul != INVALID_HANDLE_VALUE)
        CloseHandle(nul);
}

static void stop_server(void)
{
    if (g_job) {
        TerminateJobObject(g_job, 0);
        /* Give the tree a moment purely so the log file handle is released
         * before we return; the job is already gone either way. */
        if (g_child)
            WaitForSingleObject(g_child, 5000);
    }
}

/* -----------------------------------------------------------------------
 * Velopack (velopack_libc.dll) - see the "In-app updates" section of this
 * file's header comment for the whole design. Everything below is loaded
 * with LoadLibrary/GetProcAddress and touched ONLY from
 * apply_update_and_restart, never linked and never called at ordinary
 * startup.
 *
 * The structs and function shapes mirror velopack_libc's own C header
 * (Velopack.h, from the pinned velopack_libc release asset - see
 * .github/workflows/binaries.yml and rel/windows/.gitignore) field for
 * field. This is calling into the DLL's real binary layout, so "looks
 * about right" is not good enough - every shape here was checked against
 * that header directly, and against a real build of this DLL, before being
 * written down. Re-declared here rather than vendoring that header, because
 * what this file needs is nine functions and four small structs, and a
 * 500-line auto-generated header is more surface to keep in sync than it
 * saves for that.
 * ---------------------------------------------------------------------- */

/* int8_t, not a bare C `enum` (which defaults to a 4-byte int) - the real
 * header sizes this type explicitly, and a return value read at the wrong
 * width is exactly the kind of mismatch LoadLibrary's lack of compile-time
 * checking will not catch for you. Only the one value this file checks for
 * is named; the DLL can return others (an error, "no update", "the feed is
 * empty") and every one of them is treated identically below - "not
 * available", the same branch that also handles the DLL being missing
 * entirely. */
typedef int8_t vpkc_update_check_t;
#define VPKC_UPDATE_AVAILABLE ((vpkc_update_check_t)0)

typedef void vpkc_update_source_t;
typedef void vpkc_update_manager_t;

typedef struct {
    char *PackageId;
    char *Version;
    char *Type;
    char *FileName;
    char *SHA1;
    char *SHA256;
    uint64_t Size;
    char *NotesMarkdown;
    char *NotesHtml;
} vpkc_asset_t;

typedef struct {
    vpkc_asset_t *TargetFullRelease;
    vpkc_asset_t *BaseRelease;
    vpkc_asset_t **DeltasToTarget;
    size_t DeltasToTargetCount;
    bool IsDowngrade;
} vpkc_update_info_t;

/* Every field here has to be set - confirmed empirically, not assumed from
 * the header's doc comments (which call every field optional): leaving any
 * one of the five strings null makes vpkc_new_update_manager_with_source
 * fall back to auto-locating an app manifest, which fails outside a real
 * installed app and reports "not properly installed" even though the other
 * four fields were exactly right. So resolve_install_root and
 * apply_update_and_restart below compute all five explicitly rather than
 * leaning on that auto-detection. */
typedef struct {
    char *RootAppDir;
    char *UpdateExePath;
    char *PackagesDir;
    char *ManifestPath;
    char *CurrentBinaryDir;
    bool IsPortable;
} vpkc_locator_config_t;

typedef vpkc_update_source_t *(*fn_new_source_github)(const char *, const char *, bool);
typedef bool (*fn_new_manager_with_source)(vpkc_update_source_t *, void *, vpkc_locator_config_t *,
                                           vpkc_update_manager_t **);
typedef vpkc_update_check_t (*fn_check_for_updates)(vpkc_update_manager_t *, vpkc_update_info_t **);
typedef bool (*fn_download_updates)(vpkc_update_manager_t *, vpkc_update_info_t *, void *, void *);
typedef bool (*fn_wait_exit_then_apply)(vpkc_update_manager_t *, vpkc_asset_t *, bool, bool, char **,
                                        size_t);
typedef void (*fn_free_update_info)(vpkc_update_info_t *);
typedef void (*fn_free_manager)(vpkc_update_manager_t *);
typedef void (*fn_free_source)(vpkc_update_source_t *);

static HMODULE g_vpk_dll;
static fn_new_source_github p_new_source_github;
static fn_new_manager_with_source p_new_manager_with_source;
static fn_check_for_updates p_check_for_updates;
static fn_download_updates p_download_updates;
static fn_wait_exit_then_apply p_wait_exit_then_apply;
static fn_free_update_info p_free_update_info;
static fn_free_manager p_free_manager;
static fn_free_source p_free_source;

/* The same repository PairingsEngine.Updates checks via the plain GitHub
 * API for the notice - see that module's moduledoc for why the NOTICE goes
 * through the releases API directly rather than this feed, and
 * .github/workflows/binaries.yml for what publishes releases.win.json and
 * the .nupkg files this feed actually serves. */
#define VPK_REPO_URL "https://github.com/AuroraRyunix/openpairings"

/* A file-exists probe, nothing more - cheap enough to run on every startup,
 * unlike the real LoadLibrary this deliberately is not. See WinMain, and
 * the header comment's "In-app updates" section for why the two are kept
 * apart. */
static BOOL velopack_dll_present(void)
{
    WCHAR path[PATH_MAX_W];

    join(path, g_root, L"velopack_libc.dll");
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static void utf8_from_wide(char *out, size_t out_len, const WCHAR *wide)
{
    if (out_len == 0)
        return;

    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)out_len, NULL, NULL) <= 0)
        out[0] = 0;
}

/* Loads velopack_libc.dll from beside this executable - a full path, never
 * a bare filename, so this never depends on the DLL search order finding
 * the right copy. Resolves every vpkc_* entry point this file uses; any one
 * missing - a same-named file that is not really this DLL, a build that
 * shipped an older/newer one with a changed export - fails the whole load
 * rather than leaving a partial set of function pointers to call through. */
static BOOL load_velopack(void)
{
    WCHAR path[PATH_MAX_W];

    if (g_vpk_dll)
        return TRUE;

    join(path, g_root, L"velopack_libc.dll");
    g_vpk_dll = LoadLibraryW(path);
    if (!g_vpk_dll)
        return FALSE;

    p_new_source_github =
        (fn_new_source_github)GetProcAddress(g_vpk_dll, "vpkc_new_source_github");
    p_new_manager_with_source =
        (fn_new_manager_with_source)GetProcAddress(g_vpk_dll, "vpkc_new_update_manager_with_source");
    p_check_for_updates = (fn_check_for_updates)GetProcAddress(g_vpk_dll, "vpkc_check_for_updates");
    p_download_updates = (fn_download_updates)GetProcAddress(g_vpk_dll, "vpkc_download_updates");
    p_wait_exit_then_apply =
        (fn_wait_exit_then_apply)GetProcAddress(g_vpk_dll, "vpkc_wait_exit_then_apply_updates");
    p_free_update_info = (fn_free_update_info)GetProcAddress(g_vpk_dll, "vpkc_free_update_info");
    p_free_manager = (fn_free_manager)GetProcAddress(g_vpk_dll, "vpkc_free_update_manager");
    p_free_source = (fn_free_source)GetProcAddress(g_vpk_dll, "vpkc_free_source");

    if (!p_new_source_github || !p_new_manager_with_source || !p_check_for_updates ||
        !p_download_updates || !p_wait_exit_then_apply || !p_free_update_info || !p_free_manager ||
        !p_free_source) {
        FreeLibrary(g_vpk_dll);
        g_vpk_dll = NULL;
        return FALSE;
    }

    return TRUE;
}

/* Same derivation as PairingsEngine.Updates.InstallKind.detect_real/0 on
 * the Elixir side, repeated here because the launcher and the BEAM process
 * share no state: g_root ("...\<packId>\current\") has to end in exactly
 * "current", with an Update.exe one level up - anything else (a portable
 * copy someone dropped this DLL next to, say) is not a real Velopack
 * per-user install and must not be treated as one.
 *
 * Also probes that the install root is actually writable, the way
 * InstallKind does on the Elixir side (see its own comment on why a real
 * write attempt is the only honest test of this on Windows) - belt and
 * braces on the same property the Elixir side already gates the button on,
 * for the same reason the whole feature keeps checking it more than once:
 * a per-machine install must never get partway into an update attempt only
 * to fail on the write. */
static BOOL resolve_install_root(WCHAR *install_root, WCHAR *update_exe_path)
{
    WCHAR trimmed[PATH_MAX_W];
    WCHAR probe[PATH_MAX_W];
    size_t len, i;
    HANDLE probe_handle;

    lstrcpynW(trimmed, g_root, PATH_MAX_W);
    len = lstrlenW(trimmed);
    if (len > 0 && trimmed[len - 1] == L'\\')
        trimmed[len - 1] = 0;

    i = lstrlenW(trimmed);
    while (i > 0 && trimmed[i - 1] != L'\\')
        i--;

    if (i == 0 || lstrcmpiW(trimmed + i, L"current") != 0)
        return FALSE;

    trimmed[i - 1] = 0;
    lstrcpynW(install_root, trimmed, PATH_MAX_W);

    join(update_exe_path, install_root, L"\\Update.exe");
    if (GetFileAttributesW(update_exe_path) == INVALID_FILE_ATTRIBUTES)
        return FALSE;

    wsprintfW(probe, L"%s\\.openpairings-update-probe-%u", install_root, GetTickCount());
    probe_handle =
        CreateFileW(probe, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (probe_handle == INVALID_HANDLE_VALUE)
        return FALSE;
    CloseHandle(probe_handle);
    DeleteFileW(probe);

    return TRUE;
}

static void set_status(const WCHAR *status, const WCHAR *hint)
{
    SetWindowTextW(g_status, status);
    SetWindowTextW(g_hint, hint);
}

/* Restarts the server on whatever version is already on disk - the one
 * thing every failure path in apply_update_and_restart shares below, and
 * the reason none of them can be allowed to just stop. See this file's
 * header comment: an arbiter must never be left without a running program
 * because an update attempt did not work out. */
static void restart_current_version(const WCHAR *status, const WCHAR *hint)
{
    HANDLE thread;

    set_status(status, hint);
    start_server();

    thread = CreateThread(NULL, 0, waiter, NULL, 0, NULL);
    if (thread)
        CloseHandle(thread);
}

/* A thread proc, not called directly from window_proc - the check and
 * download below are real network calls that can run for the better part
 * of a minute (see the status text), and blocking the UI thread inside a
 * window procedure would freeze this window's message pump for that whole
 * time (no repaint, Windows offering to mark it "Not Responding") - exactly
 * what this window exists to never do to an arbiter. Same shape as `waiter`
 * for the same reason: SetWindowTextW from a background thread is safe -
 * it is a thin wrapper over SendMessage, which Windows marshals to the
 * owning thread automatically - and PostMessageW is safe from any thread by
 * design, so nothing here needs to hop back to the main thread to touch the
 * window.
 *
 * Runs entirely between the app's own clean exit (see WM_APP_CHILD_EXITED)
 * and either a hand-off to Velopack's own Update.exe - which restarts this
 * same launcher once it has applied the update, see the header comment -
 * or a fallback restart on the version already on disk. Every early exit
 * from this function goes through restart_current_version; there is no
 * path out of it that leaves nothing running. */
static DWORD WINAPI apply_update_and_restart(LPVOID unused)
{
    WCHAR install_root[PATH_MAX_W];
    WCHAR update_exe[PATH_MAX_W];
    WCHAR manifest[PATH_MAX_W];
    WCHAR packages[PATH_MAX_W];
    char root_u8[PATH_MAX_W * 3];
    char update_exe_u8[PATH_MAX_W * 3];
    char current_u8[PATH_MAX_W * 3];
    char manifest_u8[PATH_MAX_W * 3];
    char packages_u8[PATH_MAX_W * 3];
    vpkc_locator_config_t locator;
    vpkc_update_source_t *source = NULL;
    vpkc_update_manager_t *manager = NULL;
    vpkc_update_info_t *update = NULL;
    BOOL applied = FALSE;

    (void)unused;

    set_status(L"Checking for updates…", L"Please wait.");

    if (!resolve_install_root(install_root, update_exe))
        goto done;

    if (!load_velopack())
        goto done;

    /* "current\sq.version" is the manifest Velopack itself writes into the
     * payload at pack time - confirmed by inspecting a real packed release,
     * not assumed. "<install root>\packages" need not exist yet (Velopack
     * creates it on first use); created here so a fresh per-user install
     * that has never updated before does not fail on that alone. */
    join(manifest, g_root, L"sq.version");
    join(packages, install_root, L"\\packages");
    CreateDirectoryW(packages, NULL);

    utf8_from_wide(root_u8, sizeof root_u8, install_root);
    utf8_from_wide(update_exe_u8, sizeof update_exe_u8, update_exe);
    utf8_from_wide(current_u8, sizeof current_u8, g_root);
    utf8_from_wide(manifest_u8, sizeof manifest_u8, manifest);
    utf8_from_wide(packages_u8, sizeof packages_u8, packages);

    ZeroMemory(&locator, sizeof locator);
    locator.RootAppDir = root_u8;
    locator.UpdateExePath = update_exe_u8;
    locator.PackagesDir = packages_u8;
    locator.ManifestPath = manifest_u8;
    locator.CurrentBinaryDir = current_u8;
    locator.IsPortable = FALSE;

    source = p_new_source_github(VPK_REPO_URL, NULL, FALSE);
    if (!source)
        goto done;

    if (!p_new_manager_with_source(source, NULL, &locator, &manager) || !manager)
        goto done;

    if (p_check_for_updates(manager, &update) != VPKC_UPDATE_AVAILABLE || !update ||
        !update->TargetFullRelease)
        goto done;

    set_status(L"Downloading the update…", L"This can take a minute on a slow connection.");
    if (!p_download_updates(manager, update, NULL, NULL))
        goto done;

    set_status(L"Installing the update…", L"OpenPairings will restart in a moment.");

    /* From here, Velopack's own Update.exe (spawned by this call) is
     * watching THIS process: it waits for the launcher to exit, swaps the
     * "current" directory for the new version, and starts OpenPairings.exe
     * again - this same launcher, fresh, running WinMain from the top like
     * any other double-click. Nothing on this side restarts the server. */
    applied = p_wait_exit_then_apply(manager, update->TargetFullRelease, TRUE, TRUE, NULL, 0);

done:
    if (update)
        p_free_update_info(update);
    if (manager)
        p_free_manager(manager);
    if (source)
        p_free_source(source);

    if (applied) {
        /* Velopack is now waiting for this process to exit - get out of its
         * way. WM_CLOSE runs the ordinary teardown path (DestroyWindow ->
         * WM_DESTROY -> the message loop ending -> stop_server() in
         * WinMain), same as a manual "Stop"; stop_server() tearing down an
         * already-dead job/child is harmless. */
        PostMessageW(g_wnd, WM_CLOSE, 0, 0);
        return 0;
    }

    /* Anything at all went wrong - offline, nothing newer, a download
     * error, an apply error, or the DLL missing/blocked/not really
     * velopack_libc.dll. Every one of those looks identical from here: say
     * so, and get the arbiter back to a running OpenPairings. */
    restart_current_version(L"Could not install the update",
                            L"Starting OpenPairings on the current version instead.");
    return 0;
}

static void report_failure(int reason)
{
    WCHAR message[PATH_MAX_W + 512];
    WCHAR detail[512];

    /* The timeout is spelled from the constant rather than written out in
     * words, so changing one does not leave the other lying. */
    if (reason == FAIL_EXITED)
        wsprintfW(detail,
                  L"The server stopped on its own while starting up.\n\n"
                  L"The usual cause is that something else is already using port "
                  L"%d - another copy of OpenPairings, or another program.",
                  g_port);
    else
        wsprintfW(detail, L"The server did not answer on port %d within %d seconds.",
                  g_port, START_TIMEOUT_MS / 1000);

    wsprintfW(message,
              L"OpenPairings did not start.\n\n%s\n\n"
              L"The details are in:\n%s\n\nOpen that file now?",
              detail, g_log_path);

    if (MessageBoxW(g_wnd, message, L"OpenPairings", MB_YESNO | MB_ICONERROR) == IDYES)
        ShellExecuteW(NULL, L"open", L"notepad.exe", g_log_path, NULL, SW_SHOWNORMAL);
}

static HWND label(HWND parent, int id, const WCHAR *text, int x, int y, int w, int h,
                  HFONT font)
{
    HWND h_wnd = CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | SS_LEFT,
                                 S(x), S(y), S(w), S(h), parent, (HMENU)(INT_PTR)id,
                                 g_inst, NULL);
    SendMessageW(h_wnd, WM_SETFONT, (WPARAM)font, TRUE);
    return h_wnd;
}

static void build_controls(HWND wnd)
{
    NONCLIENTMETRICSW ncm;
    HWND icon_holder, open_button, stop_button;
    HICON icon;

    /* The shell's own message font, not DEFAULT_GUI_FONT - that stock object
     * is still Windows 95's, and one 1995 font is enough to make a window read
     * as abandonware. */
    ncm.cbSize = sizeof ncm;
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0)) {
        LOGFONTW lf = ncm.lfMessageFont;
        g_font = CreateFontIndirectW(&lf);
        lf.lfHeight = lf.lfHeight * 7 / 5;
        lf.lfWeight = FW_SEMIBOLD;
        g_title_font = CreateFontIndirectW(&lf);
    } else {
        g_font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        g_title_font = g_font;
    }

    icon = (HICON)LoadImageW(g_inst, MAKEINTRESOURCEW(1), IMAGE_ICON, S(32), S(32), 0);
    icon_holder = CreateWindowExW(0, L"STATIC", NULL,
                                  WS_CHILD | WS_VISIBLE | SS_ICON | SS_REALSIZECONTROL,
                                  S(22), S(24), S(32), S(32), wnd,
                                  (HMENU)(INT_PTR)IDC_LOGO, g_inst, NULL);
    SendMessageW(icon_holder, STM_SETICON, (WPARAM)icon, 0);

    g_status = label(wnd, IDC_STATUS, L"Starting OpenPairings…", 70, 22, 350, 26,
                     g_title_font);
    label(wnd, IDC_URL, g_url, 70, 52, 350, 20, g_font);
    /* Aligned with the two lines above it rather than with the window edge:
     * the icon owns the left margin, and text that starts in two different
     * places for no reason is the sort of thing that reads as unfinished
     * without anybody being able to say why. */
    g_hint = label(wnd, IDC_HINT,
                   L"Your web browser will open by itself as soon as it is ready.",
                   70, 86, 348, 48, g_font);

    open_button = CreateWindowExW(0, L"BUTTON", L"Open in browser",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_DISABLED |
                                      BS_DEFPUSHBUTTON,
                                  S(266), S(142), S(152), S(30), wnd,
                                  (HMENU)(INT_PTR)IDC_OPEN, g_inst, NULL);
    stop_button = CreateWindowExW(0, L"BUTTON", L"Stop OpenPairings",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                                  S(102), S(142), S(152), S(30), wnd,
                                  (HMENU)(INT_PTR)IDC_STOP, g_inst, NULL);

    SendMessageW(open_button, WM_SETFONT, (WPARAM)g_font, TRUE);
    SendMessageW(stop_button, WM_SETFONT, (WPARAM)g_font, TRUE);

    /* Quiet, under the buttons, and in the text column: something to read out
     * when asked "which version are you on", not something to act on. */
    if (g_versions[0])
        g_version = label(wnd, IDC_VERSION, g_versions, 70, 186, 348, 18, g_font);
}

static LRESULT CALLBACK window_proc(HWND wnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE:
        build_controls(wnd);
        return 0;

    case WM_CTLCOLORSTATIC:
        /* Statics default to a grey that does not match the window, and the
         * hint and version lines are deliberately quieter than the rest. */
        SetBkMode((HDC)wp, TRANSPARENT);
        SetTextColor((HDC)wp, GetSysColor((HWND)lp == g_hint || (HWND)lp == g_version
                                              ? COLOR_GRAYTEXT
                                              : COLOR_WINDOWTEXT));
        return (LRESULT)GetSysColorBrush(COLOR_WINDOW);

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_OPEN:
            open_browser();
            return 0;
        case IDC_STOP:
            SendMessageW(wnd, WM_CLOSE, 0, 0);
            return 0;
        }
        return 0;

    case WM_APP_READY:
        SetWindowTextW(g_status, L"OpenPairings is running");
        SetWindowTextW(g_hint,
                       L"Leave this window open while you work.\n"
                       L"Closing it stops OpenPairings.");
        EnableWindow(GetDlgItem(wnd, IDC_OPEN), TRUE);
        open_browser();
        return 0;

    case WM_APP_SLOW:
        SetWindowTextW(g_hint,
                       L"Still starting. The very first run takes longer, because "
                       L"OpenPairings is creating its database.");
        return 0;

    case WM_APP_FAILED:
        SetWindowTextW(g_status, L"OpenPairings did not start");
        SetWindowTextW(g_hint, L"Close this window and try again.");
        report_failure((int)wp);
        return 0;

    case WM_APP_CHILD_EXITED:
        /* The server was running and then it was not, with no window close
         * in between - see this file's "In-app updates" header section.
         * OP_UPDATE_EXIT_CODE is the one exit this application ever
         * produces on its own (PairingsEngine.Updates.request_install_and_
         * restart/0); anything else here is an actual crash, which this
         * file had no way to detect before this feature added the second
         * half of `waiter`'s wait. */
        if ((DWORD)wp == OP_UPDATE_EXIT_CODE) {
            /* Backgrounded - see apply_update_and_restart's own comment for
             * why this must not run on the window procedure's thread. */
            HANDLE thread = CreateThread(NULL, 0, apply_update_and_restart, NULL, 0, NULL);
            if (thread)
                CloseHandle(thread);
        } else {
            SetWindowTextW(g_status, L"OpenPairings stopped");
            SetWindowTextW(g_hint,
                           L"The server process ended on its own. Close this window, or "
                           L"use OpenPairings.bat to see what happened.");
            EnableWindow(GetDlgItem(wnd, IDC_OPEN), FALSE);
        }
        return 0;

    case WM_CLOSE:
        DestroyWindow(wnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(wnd, msg, wp, lp);
}

static void create_window(void)
{
    WNDCLASSEXW wc;
    RECT rect;
    HDC screen;

    screen = GetDC(NULL);
    if (screen) {
        g_dpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(NULL, screen);
    }

    ZeroMemory(&wc, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = window_proc;
    wc.hInstance = g_inst;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"OpenPairingsLauncher";
    wc.hIcon = (HICON)LoadImageW(g_inst, MAKEINTRESOURCEW(1), IMAGE_ICON, 0, 0,
                                 LR_DEFAULTSIZE);
    wc.hIconSm = (HICON)LoadImageW(g_inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON),
                                   GetSystemMetrics(SM_CYSMICON), 0);
    if (!RegisterClassExW(&wc))
        fatal(L"OpenPairings could not create its window.");

    rect.left = 0;
    rect.top = 0;
    rect.right = S(440);
    /* 24 more for the version line under the buttons, when there is one. */
    rect.bottom = S(g_versions[0] ? 214 : 190);
    /* Not resizable and not maximisable: the layout is fixed, and a status
     * window that can be dragged into a useless shape is only a way to make it
     * look broken. */
    AdjustWindowRect(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                     FALSE);

    g_wnd = CreateWindowExW(0, wc.lpszClassName, g_title,
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                            CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left,
                            rect.bottom - rect.top, NULL, NULL, g_inst, NULL);
    if (!g_wnd)
        fatal(L"OpenPairings could not create its window.");

    ShowWindow(g_wnd, SW_SHOWNORMAL);
    UpdateWindow(g_wnd);
}

/* Velopack runs the main executable with hook arguments during install, update
 * and uninstall, and waits for it to exit. Without this it would start a whole
 * server behind the installer's splash screen, and the arbiter would get a
 * running OpenPairings they did not ask for while they were still installing
 * it. --squirrel-* is the older spelling of the same hooks, which Velopack
 * still emits for apps migrating from Squirrel. */
static int starts_with(const WCHAR *text, const WCHAR *prefix)
{
    while (*prefix) {
        if (*text != *prefix)
            return 0;
        text++;
        prefix++;
    }
    return 1;
}

static int velopack_hook(void)
{
    int argc = 0, i;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    int hook = 0;

    if (!argv)
        return 0;

    for (i = 1; i < argc; i++) {
        if (starts_with(argv[i], L"--veloapp-") || starts_with(argv[i], L"--squirrel-"))
            hook = 1;
    }

    LocalFree(argv);
    return hook;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    WSADATA wsa;
    HANDLE mutex;
    WCHAR mutex_name[64];
    MSG msg;
    INITCOMMONCONTROLSEX icc;

    (void)prev;
    (void)cmdline;
    (void)show;

    g_inst = inst;

    if (velopack_hook())
        return 0;

    icc.dwSize = sizeof icc;
    icc.dwICC = ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&icc);

    resolve_root();
    read_versions();
    g_port = read_port();
    wsprintfW(g_url, L"http://localhost:%d", g_port);
    resolve_log_path();

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
        fatal(L"OpenPairings could not start Windows networking.");

    /* Local\ scopes the name to this logon session, which is the right scope
     * for a per-user install: two people on one machine via Fast User
     * Switching each get their own, and each gets their own port conflict to
     * deal with rather than a mysterious refusal. */
    wsprintfW(mutex_name, L"Local\\OpenPairings.Launcher.%d", g_port);
    mutex = CreateMutexW(NULL, TRUE, mutex_name);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        /* Double-clicking the shortcut again should show you the program you
         * already have running, not start a second one that cannot bind. */
        open_browser();
        return 0;
    }

    if (port_open()) {
        WCHAR message[512];
        wsprintfW(message,
                  L"Something is already using port %d on this computer.\n\n"
                  L"That is most likely OpenPairings itself, started another way - "
                  L"through OpenPairings.bat, or left running from an earlier "
                  L"session.\n\nOpen it in your browser?",
                  g_port);
        if (MessageBoxW(NULL, message, L"OpenPairings", MB_YESNO | MB_ICONINFORMATION) ==
            IDYES)
            open_browser();
        return 0;
    }

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

    /* Told to the app as an environment variable, the same way OPENPAIRINGS_
     * LOCAL and OPENPAIRINGS_NO_BROWSER already are below - a cheap
     * file-exists probe, not the real LoadLibrary (see velopack_dll_present
     * and this file's "In-app updates" header section for why those stay
     * apart). PairingsEngine.Updates.install_and_restart_available?/0 reads
     * this; the notice combines it with the install-kind check it already
     * makes, so a per-machine install - which gets this same DLL in its
     * payload today - still never sees the button. */
    SetEnvironmentVariableW(L"OPENPAIRINGS_UPDATE_AVAILABLE", velopack_dll_present() ? L"1" : L"0");

    create_window();
    start_server();

    /* After the window exists, so the thread always has somewhere to post to. */
    {
        HANDLE thread = CreateThread(NULL, 0, waiter, NULL, 0, NULL);
        if (thread)
            CloseHandle(thread);
    }

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(g_wnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    stop_server();
    return 0;
}
