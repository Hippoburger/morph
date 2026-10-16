import AppKit
import SwiftUI
import UserNotifications

// The Finder extension is sandboxed, so it hands its jobs over as morph://convert?to=png&size=1280&file=…
// and morph://shrink?file=… URLs. Morph runs up to three at a time with a spinner in the menu bar
// (whose menu shows progress and Cancel), posts a notification when they're done, and quits once it's
// idle unless its window is open.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    /// `ext` nil means Make Smaller.
    private struct Job { let file: URL; let ext: String?; let size: Int? }

    private var queue: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var finished = 0
    private var cancelled = false
    private var done: [URL] = []
    private var failures: [(URL, Error)] = []
    private var openedByURL = false
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var progressItem: NSMenuItem?

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
            guard url.scheme == "morph", url.host == "convert" || url.host == "shrink",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { continue }
            let ext = items.first { $0.name == "to" }?.value.map(Formats.normalize)
            guard ext != nil || url.host == "shrink" else { continue }
            let size = items.first { $0.name == "size" }?.value.flatMap { Int($0) }
            openedByURL = true
            for file in items where file.name == "file" {
                if let path = file.value { queue.append(Job(file: URL(fileURLWithPath: path), ext: ext, size: size)) }
            }
        }
        pump()
    }

    // MARK: Jobs

    /// Starts queued jobs until three are running. Each one calls back here when it ends.
    private func pump() {
        if !queue.isEmpty { showStatus() }
        while tasks.count < 3, !queue.isEmpty {
            let job = queue.removeFirst(), id = UUID()
            tasks[id] = Task {
                do {
                    if let ext = job.ext {
                        done += try await Converter.convert(job.file, to: ext, maxPixels: job.size)
                    } else {
                        done.append(try await Shrink.run(job.file))
                    }
                } catch where !cancelled {
                    failures.append((job.file, error))
                } catch {}
                tasks[id] = nil
                finished += 1
                updateProgress()
                pump()
                if tasks.isEmpty, queue.isEmpty { await finish() }
            }
        }
        updateProgress()
    }

    private func finish() async {
        hideStatus()
        let (done, failures) = (self.done, self.failures)
        (self.done, self.failures, finished, cancelled) = ([], [], 0, false)
        if !failures.isEmpty { report(failures) }
        // The first time, this waits on the notification permission prompt.
        if !done.isEmpty { await notify(done) }
        quitIfIdle()
    }

    @objc private func cancelAll() {
        cancelled = true
        queue.removeAll()
        tasks.values.forEach { $0.cancel() }
        Shell.terminateAll()
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
            if tasks.isEmpty, queue.isEmpty, window?.isVisible != true { NSApp.terminate(nil) }
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
        let menu = NSMenu()
        let progress = NSMenuItem(title: "Converting…", action: nil, keyEquivalent: "")
        progress.isEnabled = false
        menu.addItem(progress)
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelAll), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        item.menu = menu
        statusItem = item
        progressItem = progress
    }

    private func updateProgress() {
        let total = finished + tasks.count + queue.count
        let text = cancelled ? "Cancelling…" : "Converting… \(finished) of \(total) done"
        progressItem?.title = text
        statusItem?.button?.toolTip = text
    }

    private func hideStatus() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        progressItem = nil
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
        if tasks.isEmpty, queue.isEmpty { NSApp.terminate(nil) }
    }
}
