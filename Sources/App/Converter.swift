import Foundation

// Runs a conversion's plan step by step. Steps along the way write to the temporary directory; the
// last one writes next to the original, under a name that doesn't overwrite anything.

@MainActor
enum Converter {
    static func convert(_ input: URL, to dst: String) async throws -> [URL] {
        let src = Formats.normalize(input.pathExtension)
        guard let plan = Formats.plan(from: src, to: dst) else {
            throw ConversionError("Morph can't turn \(src.isEmpty ? "this file" : src.uppercased()) into \(dst.uppercased()).")
        }
        let dir = input.deletingLastPathComponent()
        var current: [(url: URL, base: String)] = [(input, input.deletingPathExtension().lastPathComponent)]
        var from = src
        var temporary: [URL] = []
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }

        for (i, ext) in plan.steps.enumerated() {
            let last = i == plan.steps.count - 1
            var next: [(url: URL, base: String)] = []
            for item in current {
                let out = last ? OutputPath.unique(in: dir, base: item.base, ext: ext) : OutputPath.temporary(ext: ext)
                let produced: [URL]
                do {
                    produced = try await step(item.url, from: from, to: ext, out: out)
                } catch {
                    try? FileManager.default.removeItem(at: out)
                    throw error
                }
                if !last { temporary += produced }
                if produced.count == 1 {
                    next.append((produced[0], item.base))
                } else {
                    next += produced.enumerated().map { ($1, "\(item.base) page \($0 + 1)") }
                }
            }
            current = next
            from = ext
        }
        return current.map(\.url)
    }

    private static func step(_ input: URL, from s: String, to d: String, out: URL) async throws -> [URL] {
        switch Formats.kind(of: s) {
        case .image:
            try await Task.detached { try ImageEngine.convert(input, from: s, to: d, out: out) }.value
            return [out]
        case .video, .audio:
            try await MediaEngine.convert(input, from: s, to: d, out: out)
            return [out]
        default:
            return try await DocumentEngine.convert(input, from: s, to: d, out: out)
        }
    }
}
