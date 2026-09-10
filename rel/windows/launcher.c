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

/* Control and message ids. WM_APP+n is the documented private range for a
 * window to talk to itself; the waiter thread uses it to report across to the
 * UI thread rather than touching controls from off-thread. */
#define IDC_LOGO 101
#define IDC_STATUS 102
#define IDC_URL 103
#define IDC_HINT 104
#define IDC_OPEN 105
#define IDC_STOP 106

#define WM_APP_READY (WM_APP + 1)
#define WM_APP_SLOW (WM_APP + 2)
#define WM_APP_FAILED (WM_APP + 3)

#define FAIL_EXITED 1
#define FAIL_TIMEOUT 2

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
static HWND g_status, g_hint;
static HFONT g_font, g_title_font;
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
            PostMessageW(g_wnd, WM_APP_READY, 0, 0);
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
}

static LRESULT CALLBACK window_proc(HWND wnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE:
        build_controls(wnd);
        return 0;

    case WM_CTLCOLORSTATIC:
        /* Statics default to a grey that does not match the window, and the
         * hint line is deliberately quieter than the rest. */
        SetBkMode((HDC)wp, TRANSPARENT);
        SetTextColor((HDC)wp,
                     GetSysColor((HWND)lp == g_hint ? COLOR_GRAYTEXT : COLOR_WINDOWTEXT));
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
    rect.bottom = S(190);
    /* Not resizable and not maximisable: the layout is fixed, and a status
     * window that can be dragged into a useless shape is only a way to make it
     * look broken. */
    AdjustWindowRect(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                     FALSE);

    g_wnd = CreateWindowExW(0, wc.lpszClassName, L"OpenPairings",
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
