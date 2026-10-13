import AppKit
import SwiftUI
import UserNotifications

// The Finder extension is sandboxed, so it hands its jobs over as morph://convert?to=png&file=…
// URLs. Morph runs them one after another with a spinner in the menu bar, posts a notification when
// they're done, and quits once it's idle unless its window is open.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var queue: [(file: URL, ext: String)] = []
    private var running = false
    private var openedByURL = false
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        if CLI.wants(args) {
            NSApp.setActivationPolicy(.prohibited)
            Task { exit(await CLI.run(args)) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        // A launch from the Finder menu delivers its URL right after this; anything else opens the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if !openedByURL { showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "morph", url.host == "convert",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let ext = items.first(where: { $0.name == "to" })?.value else { continue }
            openedByURL = true
            for file in items where file.name == "file" {
                if let path = file.value { queue.append((URL(fileURLWithPath: path), Formats.normalize(ext))) }
            }
        }
        if !running, !queue.isEmpty { Task { await drain() } }
    }

    // MARK: Jobs

    private func drain() async {
        running = true
        showStatus()
        var done: [URL] = [], failures: [(URL, Error)] = []
        while !queue.isEmpty {
            let job = queue.removeFirst()
            statusItem?.button?.toolTip = "Converting \(job.file.lastPathComponent) to \(job.ext.uppercased())…"
            do { done += try await Converter.convert(job.file, to: job.ext) } catch { failures.append((job.file, error)) }
        }
        running = false
        hideStatus()
        if !failures.isEmpty { report(failures) }
        // The first time, this waits on the notification permission prompt.
        if !done.isEmpty { await notify(done) }
        quitIfIdle()
    }

    private func notify(_ files: [URL]) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = files.count == 1 ? "Converted" : "Converted \(files.count) files"
        content.body = files.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (files.count > 3 ? "…" : "")
        content.userInfo = ["paths": files.map(\.path)]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    private func report(_ failures: [(URL, Error)]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let missing = failures.compactMap { $0.1 as? MissingToolError }.first?.tool
        if let missing {
            alert.messageText = "This conversion needs \(missing.displayName)"
            alert.informativeText = "Install it from Terminal, then try again:\n\n\(missing.installCommand)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = failures.count == 1 ? "Couldn't convert \(failures[0].0.lastPathComponent)" : "Couldn't convert \(failures.count) files"
            alert.informativeText = failures.prefix(5).map { failures.count == 1 ? $0.1.localizedDescription : "\($0.0.lastPathComponent): \($0.1.localizedDescription)" }.joined(separator: "\n")
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, let missing {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(missing.installCommand, forType: .string)
        }
    }

    private func quitIfIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            if !running, queue.isEmpty, window?.isVisible != true { NSApp.terminate(nil) }
        }
    }

    // MARK: Menu bar

    private func showStatus() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        if let button = item.button {
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                         spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        }
        statusItem = item
    }

    private func hideStatus() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Morph"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: HomeView())
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !running { NSApp.terminate(nil) }
    }
}
