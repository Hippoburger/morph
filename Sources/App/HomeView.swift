import FinderSync
import SwiftUI

// The window you get by opening Morph: whether the Finder menu is on, which optional tools are
// installed, and every format, dimmed where writing it needs a tool that isn't.

struct HomeView: View {
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var installed = Set(Tool.allCases.filter { $0.path != nil })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                finderCard
                toolsCard
                formats
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        installed = Set(Tool.allCases.filter { $0.path != nil })
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Morph").font(.title.bold())
                Text("Right-click a file in Finder and choose Convert to.").foregroundStyle(.secondary)
            }
        }
    }

    private var finderCard: some View {
        card {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finder menu").font(.headline)
                        Text(extensionEnabled ? "On. It shows up when you right-click a file." : "Off. Turn on Morph under File Providers & Finder extensions.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: { statusDot(extensionEnabled) }
                Spacer()
                if !extensionEnabled {
                    Button("Turn On…") { FIFinderSyncController.showExtensionManagementInterface() }
                }
            }
        }
    }

    private var toolsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Optional tools").font(.headline)
                toolRow(.ffmpeg, adds: "MP3, OGG, Opus, WebM, MKV, AVI and WebP, and video from any format")
                Divider()
                toolRow(.libreoffice, adds: "PowerPoint, Excel and OpenDocument slides and sheets, and sharper Word to PDF")
            }
        }
    }

    private func toolRow(_ tool: Tool, adds: String) -> some View {
        let has = installed.contains(tool)
        return HStack(alignment: .top) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName).fontWeight(.medium)
                    Text(has ? "Installed" : "Adds \(adds).").font(.callout).foregroundStyle(.secondary)
                    if !has {
                        Text(tool.installCommand).font(.callout.monospaced()).textSelection(.enabled).padding(.top, 2)
                    }
                }
            } icon: { statusDot(has) }
            Spacer()
            if !has {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.installCommand, forType: .string)
                }
            }
        }
    }

    private var formats: some View {
        let categories = Formats.byCategory
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: categories.count, by: 2)), id: \.self) { i in
                GridRow {
                    ForEach(categories[i..<min(i + 2, categories.count)], id: \.0) { category, exts in
                        formatCard(category, exts)
                    }
                }
            }
        }
    }

    private func formatCard(_ category: Category, _ exts: [String]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(category.rawValue).font(.headline)
                    Spacer()
                    Text("\(exts.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    ForEach(exts, id: \.self) { ext in chip(ext) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Dimmed when no format can be turned into this one without a tool that isn't installed.
    private func chip(_ ext: String) -> some View {
        let needs = writeNeeds(ext)
        let available = needs.map { installed.contains($0) } ?? true
        return Text(ext.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(available ? 1 : 0.4)
            .help(available ? "" : "Needs \(needs!.displayName)")
    }

    private func writeNeeds(_ ext: String) -> Tool? {
        let all = Formats.byCategory.flatMap(\.1)
        var tool: Tool?
        for s in all {
            switch Formats.plan(from: s, to: ext)?.need {
            case .native?: return nil
            case .tool(let t)?: tool = t
            case nil: continue
            }
        }
        return tool
    }

    private func statusDot(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(on ? .green : .secondary)
            .font(.title3)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
