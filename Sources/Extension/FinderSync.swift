import Cocoa
import FinderSync

// Adds Convert to ▸ to Finder's right-click menu for files Morph can convert. The extension is
// sandboxed, so it does no converting itself: it opens a morph:// URL and the app takes it from there.
// Finder copies the menu before showing it and keeps little besides titles, so the chosen format is
// read back from the item's title.

@objc(MorphFinderSync)
final class MorphFinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty,
              !urls.contains(where: \.hasDirectoryPath) else { return nil }
        let targets = Formats.commonTargets(for: Set(urls.map { Formats.normalize($0.pathExtension) }))
        guard !targets.isEmpty else { return nil }

        let submenu = NSMenu(title: "Convert to")
        var lastCategory: Category?
        for target in targets {
            let category = Formats.category(of: target.ext)
            if let lastCategory, lastCategory != category { submenu.addItem(.separator()) }
            lastCategory = category
            var title = target.ext.uppercased()
            if case .tool(let tool) = target.need, tool.path == nil { title += "  (needs \(tool.displayName))" }
            submenu.addItem(NSMenuItem(title: title, action: #selector(convert(_:)), keyEquivalent: ""))
        }
        let root = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return menu
    }

    @IBAction func convert(_ sender: AnyObject?) {
        guard let title = (sender as? NSMenuItem)?.title,
              let ext = title.split(separator: " ").first.map({ $0.lowercased() }),
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "morph"
        components.host = "convert"
        // URLComponents leaves & = + alone in query values, and file names can have any of them.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func item(_ name: String, _ value: String) -> URLQueryItem {
            URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        components.percentEncodedQueryItems = [item("to", ext)] + urls.map { item("file", $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
