// OpenPairings.app's own executable: Contents/MacOS/OpenPairings.
//
// Compiled by rel/macos/build_app.sh on the macOS runner, with nothing but
// swiftc and the system's AppKit: no Xcode project, no storyboard, no
// SwiftUI, no package. One file, so that what runs is what is read here.
//
// It exists for the Dock. The app used to be a shell script with an
// AppleScript dialog for a face and LSUIElement set, which meant no Dock
// icon, nothing in Cmd-Tab and nothing to keep in the Dock. This is a plain
// AppKit program instead, and it does only the parts a person sees:
//
//   * a Dock icon (running dot, Options > Keep in Dock, Cmd-Tab);
//   * a small window: the name, what the server is doing, "Open in browser"
//     and "Stop OpenPairings". Closing the window only hides it; clicking
//     the Dock icon brings it back; the Dock's menu has "Open in browser";
//   * the browser, opened once the server answers;
//   * Quit (Cmd-Q, the Dock's Quit, the Stop button, logout, shutdown, a
//     SIGTERM) stops the server cleanly before the app goes. No question
//     first: OpenPairings never asked on Windows or in the old Mac window.
//
// The server itself is still started and stopped by Contents/Resources/
// launcher.sh (rel/macos/launcher.sh), the child of this program. That
// script holds every rule about the environment - local mode, loopback,
// distribution off, nothing written into the bundle - and there is one copy
// of those rules, in the file the tests read. Its output (and so the
// server's) goes to logs/server.log in the data folder: a fresh file on
// every start, the previous run kept once as server.log.1.
//
// Headless (CI): `--headless`, or OPENPAIRINGS_LAUNCHER_NO_UI=1, runs the
// script with this program's own output and no window, and passes SIGTERM,
// SIGINT and SIGHUP on. That is how the build job starts this exact binary
// on a runner nobody is looking at.

import AppKit
import Foundation

// MARK: - What this app is

let appName = "OpenPairings"
let defaultPort = 4000
// The page that has to answer before the server counts as up: the same one
// launcher.sh asks for.
let probePath = "/"
let dataEnv = "OPENPAIRINGS_DATA_DIR"
let defaultDataFolder = "Library/Application Support/OpenPairings"
let headlessEnv = "OPENPAIRINGS_LAUNCHER_NO_UI"
let releaseInResources = "app/bin/pairings_engine_portable"
// OpenPairings stops when told to. Alnasl's twin of this file asks first.
let askBeforeStopping = false

// MARK: - Words

// English, or Dutch when the Mac's first language is Dutch. The site has its
// own language setting; this window is on screen before anything could read
// it.
let dutch = (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("nl")

func tr(_ english: String, _ nederlands: String) -> String {
    return dutch ? nederlands : english
}

// MARK: - Where things are

let environment = ProcessInfo.processInfo.environment
let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
let contentsPath = resources.deletingLastPathComponent().path
let scriptPath = resources.appendingPathComponent("launcher.sh").path
let releasePath = resources.appendingPathComponent(releaseInResources).path
let port = Int(environment["PORT"] ?? "") ?? defaultPort
let browserURL = URL(string: "http://localhost:\(port)")!
let probeURL = URL(string: "http://127.0.0.1:\(port)\(probePath)")!
// The Details window asks the server about itself here, with this start's secret.
let launcherTokenEnv = "OPENPAIRINGS_LAUNCHER_TOKEN"
let statsURL = URL(string: "http://127.0.0.1:\(port)/_launcher/stats?lang=\(dutch ? "nl" : "en")")!
let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
let title = version.isEmpty ? appName : "\(appName) \(version)"

func dataFolder() -> String {
    if let set = environment[dataEnv], !set.isEmpty { return set }
    return (NSHomeDirectory() as NSString).appendingPathComponent(defaultDataFolder)
}

// MARK: - Signals

// Caught, not ignored: an ignored signal stays ignored in every child, and a
// shell that starts with SIGTERM ignored cannot trap it - launcher.sh would
// then never stop its server. A caught signal is reset in the child.
var signalSources: [DispatchSourceSignal] = []

func onStopSignals(_ handler: @escaping () -> Void) {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { _ in }
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }
}

func serverProcess() -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = [scriptPath]
    child.standardInput = FileHandle.nullDevice
    return child
}

// MARK: - Headless

func runHeadless() -> Never {
    let child = serverProcess()
    child.terminationHandler = { finished in
        let status = finished.terminationStatus
        exit(finished.terminationReason == .uncaughtSignal ? 128 + status : status)
    }
    onStopSignals {
        if child.isRunning { kill(child.processIdentifier, SIGTERM) }
    }
    do {
        try child.run()
    } catch {
        FileHandle.standardError.write("\(appName): cannot run \(scriptPath): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    dispatchMain()
}

// MARK: - The app

// MARK: - Details

// The window behind the "Details" button: the numbers the running server
// reports about itself (GET /_launcher/stats, a request from this machine
// carrying this start's secret - docs/launcher-details.md) over the end of
// its own log, with Copy and Open log folder. A window of its own rather than
// a section of the small one, so the small one never changes size. While it
// is closed nothing here runs.
let logReadBytes: UInt64 = 128 * 1024
let logTailLines = 500
let copyLogLines = 200

final class DetailsWindow: NSObject, NSWindowDelegate {
    let session: URLSession
    let token: String
    let logPath: String

    var window: NSWindow!
    var statsView: NSTextView!
    var logView: NSTextView!
    var logScroll: NSScrollView!
    var copyButton: NSButton!
    var timer: Timer?
    var ticks = 0
    var asking = false
    var statsShown = ""
    var logSeenSize: UInt64 = UInt64.max

    let statsFont = NSFont.systemFont(ofSize: 12)
    // monospacedSystemFont is macOS 10.15; the Intel build reaches back to
    // 10.13, where Menlo has been the terminal's font all along.
    let logFont: NSFont = {
        if #available(macOS 10.15, *) {
            return NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        return NSFont(name: "Menlo", size: 11) ?? NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11)
    }()

    init(session: URLSession, token: String, logPath: String) {
        self.session = session
        self.token = token
        self.logPath = logPath
        super.init()
    }

    var waitingText: String {
        return tr("Waiting for \(appName) to answer...", "Wachten tot \(appName) antwoordt...")
    }

    // MARK: Window

    func makeTextArea(frame: NSRect) -> (NSScrollView, NSTextView) {
        let scroll: NSScrollView
        if #available(macOS 10.14, *) {
            scroll = NSTextView.scrollableTextView()
        } else {
            // What scrollableTextView() does, by hand, for 10.13.
            scroll = NSScrollView(frame: frame)
            let inner = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            inner.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            inner.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            inner.isVerticallyResizable = true
            inner.autoresizingMask = [.width]
            inner.textContainer?.widthTracksTextView = true
            scroll.documentView = inner
        }
        scroll.frame = frame
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = (scroll.documentView as? NSTextView) ?? NSTextView(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        return (scroll, text)
    }

    func build() {
        let width: CGFloat = 600
        let height: CGFloat = 560
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = tr("\(appName) details", "\(appName) details")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 420)
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = content

        // Bottom to top: the buttons, the log (takes the extra height), the
        // numbers (pinned to the top).
        let (statsScroll, stats) = makeTextArea(
            frame: NSRect(x: 16, y: 350, width: width - 32, height: 194))
        statsScroll.autoresizingMask = [.width, .minYMargin]
        statsView = stats
        content.addSubview(statsScroll)

        let (log, logText) = makeTextArea(
            frame: NSRect(x: 16, y: 52, width: width - 32, height: 288))
        log.autoresizingMask = [.width, .height]
        logScroll = log
        logView = logText
        content.addSubview(log)

        copyButton = NSButton(title: tr("Copy", "Kopieer"), target: self, action: #selector(copyClicked(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 16, y: 12, width: 130, height: 28)
        content.addSubview(copyButton)

        let folder = NSButton(title: tr("Open log folder", "Open logmap"), target: self,
                              action: #selector(folderClicked(_:)))
        folder.bezelStyle = .rounded
        folder.frame = NSRect(x: 156, y: 12, width: 150, height: 28)
        content.addSubview(folder)

        window.center()
    }

    func fill(_ view: NSTextView, _ text: String, font: NSFont) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    // MARK: Show and hide

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        timer?.invalidate()
        ticks = 0
        fill(statsView, statsShown.isEmpty ? waitingText : statsShown, font: statsFont)
        refreshLog(force: true)
        askServer()
        let repeating = Timer(timeInterval: 1, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
        RunLoop.main.add(repeating, forMode: .common)
        timer = repeating
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    @objc func tick() {
        ticks += 1
        refreshLog(force: false)
        if ticks % 2 == 0 { askServer() }
    }

    // MARK: The numbers

    func askServer() {
        guard !asking else { return }
        asking = true
        var request = URLRequest(url: statsURL)
        request.setValue(token, forHTTPHeaderField: "x-launcher-token")
        request.timeoutInterval = 2
        session.dataTask(with: request) { [weak self] data, response, error in
            var text: String? = nil
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let body = data,
               let json = try? JSONSerialization.jsonObject(with: body),
               let object = json as? [String: Any],
               let lines = object["summary"] as? [[String: Any]] {
                let rows = lines.compactMap { line -> String? in
                    guard let label = line["label"] as? String,
                          let value = line["value"] as? String else { return nil }
                    return "\(label): \(value)"
                }
                if !rows.isEmpty { text = rows.joined(separator: "\n") }
            }
            DispatchQueue.main.async { self?.gotStats(text) }
        }.resume()
    }

    func gotStats(_ text: String?) {
        asking = false
        // An answer replaces what is shown; no answer leaves the last one,
        // or says it is waiting if there never was one.
        if let answer = text {
            if answer != statsShown {
                statsShown = answer
                fill(statsView, answer, font: statsFont)
            }
        } else if statsShown.isEmpty {
            fill(statsView, waitingText, font: statsFont)
        }
    }

    // MARK: The log

    // The last `maxLines` lines of the log, read from the end so a long log
    // costs no more than a short one, and the file's size at the time.
    func tailLog(maxLines: Int) -> (text: String, size: UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
        do {
            let size: UInt64
            let from: UInt64
            let data: Data
            if #available(macOS 10.15.4, *) {
                defer { try? handle.close() }
                size = try handle.seekToEnd()
                from = size > logReadBytes ? size - logReadBytes : 0
                try handle.seek(toOffset: from)
                data = try handle.readToEnd() ?? Data()
            } else {
                // The Intel build reaches back to 10.13, which has only
                // the older calls (deprecated since, and they do the same).
                size = handle.seekToEndOfFile()
                from = size > logReadBytes ? size - logReadBytes : 0
                handle.seek(toFileOffset: from)
                data = handle.readDataToEndOfFile()
                handle.closeFile()
            }
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            // Started in the middle of a line: drop the fragment.
            if from > 0 && !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
            return (lines.joined(separator: "\n"), size)
        } catch {
            return nil
        }
    }

    func atBottom() -> Bool {
        return logScroll.contentView.bounds.maxY >= logView.frame.height - 24
    }

    func refreshLog(force: Bool) {
        // Somebody is selecting, or has scrolled up to read: leave it alone.
        if !force && (logView.selectedRange().length > 0 || !atBottom()) { return }
        guard let tail = tailLog(maxLines: logTailLines) else {
            if force {
                fill(logView, tr("No log yet:", "Nog geen logboek:") + "\n" + logPath, font: logFont)
            }
            return
        }
        if !force && tail.size == logSeenSize { return }
        logSeenSize = tail.size
        fill(logView, tail.text, font: logFont)
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: The buttons

    @objc func copyClicked(_ sender: Any?) {
        let log = tailLog(maxLines: copyLogLines)?.text ?? ""
        let text = "\(title)\n\n\(statsShown)\n\n\(logPath)\n\(log)\n"
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copyButton.title = tr("Copied", "Gekopieerd")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = tr("Copy", "Kopieer")
        }
    }

    @objc func folderClicked(_ sender: Any?) {
        let file = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    enum State { case starting, running, stopping, stopped }

    var state = State.starting
    var window: NSWindow!
    var statusLabel: NSTextField!
    var hintLabel: NSTextField!
    var openButton: NSButton!
    var stopButton: NSButton!
    var detailsButton: NSButton!
    var details: DetailsWindow?
    // This start's secret for the stats endpoint; handed to the server in its
    // environment, never written anywhere.
    var launcherToken = ""
    var child: Process?
    var pollTimer: Timer?
    var probing = false
    var startedAt = Date()
    var logPath = ""
    // A reply to applicationShouldTerminate is owed once the server is down.
    var replyOwed = false
    // Logout, shutdown or a signal: stop without asking anything.
    var noQuestions = false

    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Loopback never goes through a proxy, whatever the network says.
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    // MARK: Start

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("the server is running")
        buildMenus()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(powerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)
        onStopSignals { [weak self] in
            self?.noQuestions = true
            NSApp.terminate(nil)
        }

        let files = FileManager.default
        guard files.isExecutableFile(atPath: releasePath), files.fileExists(atPath: scriptPath) else {
            failAndQuit(tr(
                "\(appName) is incomplete: the program is missing from inside the app. Download it again and replace this copy.",
                "\(appName) is onvolledig: het programma ontbreekt in de app. Download het opnieuw en vervang deze kopie."))
            return
        }

        // Already running (another copy of the app, or a terminal): show it,
        // do not start a second server that cannot bind.
        probe { [weak self] answers in
            guard let self = self else { return }
            if answers {
                self.openBrowser()
                NSApp.terminate(nil)
            } else {
                self.startServer()
            }
        }
    }

    func startServer() {
        let data = dataFolder()
        let files = FileManager.default
        // The server's output: <data>/logs/server.log, started afresh on
        // every start, with the previous run kept once as server.log.1. One
        // run per file, so whatever reads it (a person, or a later Details
        // section in this window) can tail it from the top without finding
        // last week first.
        let logs = (data as NSString).appendingPathComponent("logs")
        logPath = (logs as NSString).appendingPathComponent("server.log")
        let previous = logPath + ".1"
        do {
            try files.createDirectory(atPath: logs, withIntermediateDirectories: true)
            if files.fileExists(atPath: logPath) {
                if files.fileExists(atPath: previous) { try files.removeItem(atPath: previous) }
                try files.moveItem(atPath: logPath, toPath: previous)
            }
        } catch {
            // A log that cannot be rotated is simply started afresh below.
        }
        // createFile replaces whatever is there: the truncation.
        guard files.fileExists(atPath: logs),
              files.createFile(atPath: logPath, contents: nil),
              let log = FileHandle(forWritingAtPath: logPath) else {
            failAndQuit(tr("\(appName) cannot create its data folder: \(data)",
                           "\(appName) kan zijn gegevensmap niet maken: \(data)"))
            return
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        log.write("=== \(stamp.string(from: Date())) \(title) from \(contentsPath)\n".data(using: .utf8)!)

        let server = serverProcess()
        var env = environment
        env[dataEnv] = data
        env["PORT"] = String(port)
        launcherToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        env[launcherTokenEnv] = launcherToken
        env.removeValue(forKey: headlessEnv)
        server.environment = env
        server.standardOutput = log
        server.standardError = log
        server.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.serverEnded(status: status) }
        }
        do {
            try server.run()
        } catch {
            failAndQuit(tr(
                "\(appName) is incomplete: the program is missing from inside the app. Download it again and replace this copy.",
                "\(appName) is onvolledig: het programma ontbreekt in de app. Download het opnieuw en vervang deze kopie."))
            return
        }
        child = server
        startedAt = Date()

        buildWindow()
        setState(.starting)
        showWindow()

        let timer = Timer(timeInterval: 1, target: self, selector: #selector(poll),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc func poll() {
        guard state == .starting, !probing else { return }
        if Date().timeIntervalSince(startedAt) > 15 {
            hintLabel.stringValue = tr(
                "Still starting. The very first run takes longer, because \(appName) is creating its database.",
                "Nog bezig met starten. De allereerste keer duurt langer, omdat \(appName) zijn database aanmaakt.")
        }
        probing = true
        probe { [weak self] answers in
            guard let self = self else { return }
            self.probing = false
            if answers && self.state == .starting {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.setState(.running)
                self.openBrowser()
            }
        }
    }

    func probe(_ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 2
        session.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answers = error == nil && code > 0 && code < 400
            DispatchQueue.main.async { done(answers) }
        }.resume()
    }

    // MARK: The server ended

    func serverEnded(status: Int32) {
        child = nil
        pollTimer?.invalidate()
        pollTimer = nil
        let was = state
        setState(.stopped)

        switch was {
        case .stopping:
            if replyOwed {
                replyOwed = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        case .starting:
            // launcher.sh's exit codes; see its header.
            switch status {
            case 0:
                // Another copy answered first, so the script left it alone.
                openBrowser()
                NSApp.terminate(nil)
            case 2:
                failAndQuit(tr(
                    "\(appName) is incomplete: the program is missing from inside the app. Download it again and replace this copy.",
                    "\(appName) is onvolledig: het programma ontbreekt in de app. Download het opnieuw en vervang deze kopie."))
            case 3:
                failAndQuit(tr("\(appName) cannot create its data folder: \(dataFolder())",
                               "\(appName) kan zijn gegevensmap niet maken: \(dataFolder())"))
            case 5:
                failAndQuit(tr(
                    "\(appName) did not answer within two minutes, and has been stopped. What it said is in: \(logPath)",
                    "\(appName) antwoordde niet binnen twee minuten en is gestopt. Wat het zei, staat in: \(logPath)"))
            default:
                failAndQuit(tr("\(appName) stopped while starting. What it said is in: \(logPath)",
                               "\(appName) stopte tijdens het starten. Wat het zei, staat in: \(logPath)"))
            }
        case .running:
            failAndQuit(tr("\(appName) has stopped unexpectedly. What it said is in: \(logPath)",
                           "\(appName) is onverwacht gestopt. Wat het zei, staat in: \(logPath)"))
        case .stopped:
            break
        }
    }

    func failAndQuit(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Stopping

    @objc func powerOff(_ notification: Notification) {
        noQuestions = true
    }

    @objc func stopClicked(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = child, server.isRunning else { return .terminateNow }
        if state == .stopping {
            replyOwed = true
            return .terminateLater
        }

        if askBeforeStopping && !noQuestions {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = confirmText
            alert.addButton(withTitle: stopText)
            let keep = alert.addButton(withTitle: keepText)
            keep.keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            guard let still = child, still.isRunning else { return .terminateNow }
        }

        replyOwed = true
        stopServer()
        return .terminateLater
    }

    func stopServer() {
        guard let server = child, server.isRunning else { return }
        setState(.stopping)
        // launcher.sh gives the BEAM twenty seconds before insisting; this
        // gives launcher.sh thirty, and then insists on it.
        kill(server.processIdentifier, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if let late = self?.child, late.isRunning { kill(late.processIdentifier, SIGKILL) }
        }
    }

    // MARK: The Dock

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: openText, action: #selector(openClicked(_:)), keyEquivalent: "")
        open.target = self
        open.isEnabled = state == .running
        menu.addItem(open)
        return menu
    }

    @objc func openClicked(_ sender: Any?) {
        openBrowser()
    }

    @objc func detailsClicked(_ sender: Any?) {
        if details == nil {
            details = DetailsWindow(session: session, token: launcherToken, logPath: logPath)
        }
        details?.show()
    }

    func openBrowser() {
        NSWorkspace.shared.open(browserURL)
    }

    // MARK: Words used in more than one place

    var openText: String { tr("Open in browser", "Openen in browser") }
    var stopText: String { tr("Stop \(appName)", "\(appName) stoppen") }
    var detailsText: String { tr("Details", "Details") }
    var keepText: String { tr("Keep running", "Laten draaien") }
    var confirmText: String { "" }

    // MARK: The window

    func setState(_ new: State) {
        state = new
        guard window != nil else { return }
        switch new {
        case .starting:
            statusLabel.stringValue = tr("Starting \(appName)...", "\(appName) wordt gestart...")
            hintLabel.stringValue = tr("The browser opens by itself once \(appName) answers.",
                                       "De browser opent vanzelf zodra \(appName) antwoordt.")
            openButton.isEnabled = false
            stopButton.isEnabled = true
        case .running:
            statusLabel.stringValue = tr("\(appName) is running at \(browserURL.absoluteString).",
                                         "\(appName) draait op \(browserURL.absoluteString).")
            hintLabel.stringValue = tr(
                "You can close this window: \(appName) keeps running in the Dock. Quitting it stops the program; your tournaments stay saved.",
                "Je kunt dit venster sluiten: \(appName) blijft in het Dock draaien. Stop je het, dan stopt het programma; je toernooien blijven bewaard.")
            openButton.isEnabled = true
            stopButton.isEnabled = true
        case .stopping:
            statusLabel.stringValue = tr("Stopping \(appName)...", "\(appName) wordt gestopt...")
            hintLabel.stringValue = ""
            openButton.isEnabled = false
            stopButton.isEnabled = false
        case .stopped:
            statusLabel.stringValue = tr("\(appName) has stopped.", "\(appName) is gestopt.")
            hintLabel.stringValue = ""
            openButton.isEnabled = false
            stopButton.isEnabled = false
        }
    }

    func showWindow() {
        guard window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // The window is a vertical stack of sections; today it holds one, the
    // summary (icon, name, status, hint, the buttons), laid out by hand in a
    // fixed-size view. Details is a window of its own (DetailsWindow), so
    // this one never changes size.
    var sections: NSStackView!

    func buildWindow() {
        let width: CGFloat = 500
        let height: CGFloat = 180
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.isReleasedWhenClosed = false

        sections = NSStackView()
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 0
        sections.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let summary = buildSummary(width: width, height: height)
        summary.translatesAutoresizingMaskIntoConstraints = false
        sections.addArrangedSubview(summary)
        NSLayoutConstraint.activate([
            summary.widthAnchor.constraint(equalToConstant: width),
            summary.heightAnchor.constraint(equalToConstant: height),
        ])

        window.contentView = sections
        window.center()
    }

    func buildSummary(width: CGFloat, height: CGFloat) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let icon = NSImageView(frame: NSRect(x: 20, y: height - 84, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let left: CGFloat = 104
        let textWidth = width - left - 20

        let name = NSTextField(labelWithString: title)
        name.font = NSFont.boldSystemFont(ofSize: 15)
        name.frame = NSRect(x: left, y: height - 44, width: textWidth, height: 22)
        content.addSubview(name)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.frame = NSRect(x: left, y: height - 86, width: textWidth, height: 38)
        statusLabel.isSelectable = true
        content.addSubview(statusLabel)

        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: left, y: 58, width: textWidth, height: 36)
        content.addSubview(hintLabel)

        openButton = NSButton(title: openText, target: self, action: #selector(openClicked(_:)))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.sizeToFit()
        stopButton = NSButton(title: stopText, target: self, action: #selector(stopClicked(_:)))
        stopButton.bezelStyle = .rounded
        stopButton.sizeToFit()

        let openWidth = max(openButton.frame.width + 16, 120)
        let stopWidth = max(stopButton.frame.width + 16, 120)
        openButton.frame = NSRect(x: width - 20 - openWidth, y: 14, width: openWidth, height: 32)
        stopButton.frame = NSRect(x: openButton.frame.minX - 10 - stopWidth, y: 14, width: stopWidth, height: 32)
        content.addSubview(openButton)
        content.addSubview(stopButton)

        detailsButton = NSButton(title: detailsText, target: self, action: #selector(detailsClicked(_:)))
        detailsButton.bezelStyle = .rounded
        detailsButton.frame = NSRect(x: 20, y: 14, width: 100, height: 32)
        content.addSubview(detailsButton)
        return content
    }

    // MARK: Menus

    func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("About \(appName)", "Over \(appName)"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: tr("Hide \(appName)", "Verberg \(appName)"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: tr("Hide Others", "Verberg andere"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("Show All", "Toon alles"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: tr("Quit \(appName)", "Stop \(appName)"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: tr("Window", "Venster"))
        windowMenu.addItem(withTitle: tr("Minimize", "Minimaliseer"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: tr("Close", "Sluit venster"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(NSMenuItem.separator())
        let open = windowMenu.addItem(withTitle: openText, action: #selector(openClicked(_:)),
                                      keyEquivalent: "o")
        open.target = self
        let detailsItem = windowMenu.addItem(withTitle: detailsText, action: #selector(detailsClicked(_:)),
                                             keyEquivalent: "d")
        detailsItem.target = self
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openClicked(_:)) { return state == .running }
        return true
    }
}

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--headless") || environment[headlessEnv] == "1" {
    runHeadless()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
