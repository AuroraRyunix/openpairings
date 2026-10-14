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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    enum State { case starting, running, stopping, stopped }

    var state = State.starting
    var window: NSWindow!
    var statusLabel: NSTextField!
    var hintLabel: NSTextField!
    var openButton: NSButton!
    var stopButton: NSButton!
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

    func openBrowser() {
        NSWorkspace.shared.open(browserURL)
    }

    // MARK: Words used in more than one place

    var openText: String { tr("Open in browser", "Openen in browser") }
    var stopText: String { tr("Stop \(appName)", "\(appName) stoppen") }
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

    // The window is a vertical stack of sections. Today it holds one: the
    // summary (icon, name, status, hint, the two buttons), laid out by hand
    // in a fixed-size view. A later section - a collapsible "Details" with
    // the server's log (logPath) and its numbers - goes in with
    // `sections.addArrangedSubview(...)` below the summary and is shown or
    // hidden with `isHidden`; the stack's constraints resize the window, and
    // nothing in the summary moves.
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
