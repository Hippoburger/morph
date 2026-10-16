import Cocoa
import FinderSync

// Adds Convert to ▸ and Make Smaller to Finder's right-click menu. The extension is sandboxed, so it
// does no converting itself: it opens a morph:// URL and the app takes it from there. Finder copies
// the menu before showing it and keeps little besides titles, so the chosen format and size are read
// back from the item's title ("JPG — Medium, 1280 px").

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
        let sources = Set(urls.map { Formats.normalize($0.pathExtension) })
        let targets = Formats.commonTargets(for: sources)
        let images = sources.allSatisfy { Formats.kind(of: $0) == .image }
        let menu = NSMenu(title: "")

        let submenu = NSMenu(title: "Convert to")
        var lastCategory: Category?
        for target in targets {
            let category = Formats.category(of: target.ext)
            if let lastCategory, lastCategory != category { submenu.addItem(.separator()) }
            lastCategory = category
            let name = target.ext.uppercased()
            var title = name
            if case .tool(let tool) = target.need, tool.path == nil { title += "  (needs \(tool.displayName))" }
            let item = NSMenuItem(title: title, action: #selector(convert(_:)), keyEquivalent: "")
            if images, Formats.kind(of: target.ext) == .image {
                item.action = nil
                item.submenu = NSMenu(title: title)
                item.submenu?.addItem(NSMenuItem(title: "\(name) — Full Size", action: #selector(convert(_:)), keyEquivalent: ""))
                for (size, pixels) in Formats.sizes {
                    item.submenu?.addItem(NSMenuItem(title: "\(name) — \(size), \(pixels) px", action: #selector(convert(_:)), keyEquivalent: ""))
                }
            }
            submenu.addItem(item)
        }
        if !targets.isEmpty {
            let root = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
            root.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            root.submenu = submenu
            menu.addItem(root)
        }
        if sources.isSubset(of: Formats.shrinkable) {
            let shrink = NSMenuItem(title: "Make Smaller", action: #selector(shrink(_:)), keyEquivalent: "")
            shrink.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
            menu.addItem(shrink)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @IBAction func convert(_ sender: AnyObject?) {
        guard let words = (sender as? NSMenuItem)?.title.split(separator: " "), let ext = words.first?.lowercased() else { return }
        let size = words.firstIndex(of: "px").flatMap { Int(words[$0 - 1]) }
        open("convert", [("to", ext)] + (size.map { [("size", String($0))] } ?? []))
    }

    @IBAction func shrink(_ sender: AnyObject?) {
        open("shrink", [])
    }

    private func open(_ action: String, _ params: [(String, String)]) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "morph"
        components.host = action
        // URLComponents leaves & = + alone in query values, and file names can have any of them.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func item(_ name: String, _ value: String) -> URLQueryItem {
            URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        components.percentEncodedQueryItems = params.map(item) + urls.map { item("file", $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
