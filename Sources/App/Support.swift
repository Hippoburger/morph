import Foundation

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct MissingToolError: LocalizedError {
    let tool: Tool
    var errorDescription: String? { "This conversion needs \(tool.displayName). Install it with: \(tool.installCommand)" }
}

enum Shell {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<Process> = []

    /// Stops every tool Morph started, for Cancel. Their `run` calls then throw.
    static func terminateAll() {
        lock.withLock { running.forEach { $0.terminate() } }
    }

    /// Runs a tool to completion and returns its output; throws with the last lines of it on failure.
    @discardableResult
    static func run(_ path: String, _ args: [String], in directory: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = directory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        lock.withLock { _ = running.insert(p) }
        defer { lock.withLock { _ = running.remove(p) } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let tail = output.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw ConversionError("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(tail)")
        }
        return output
    }
}

enum FFmpeg {
    /// The encoders the installed ffmpeg was built with, read once.
    static let encoders: Set<String> = {
        guard let path = Tool.ffmpeg.path, let out = try? Shell.run(path, ["-hide_banner", "-encoders"]) else { return [] }
        // Lines look like " V....D libx264    libx264 H.264 / AVC ..."
        return Set(out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, parts[0] != "------" else { return nil }
            return String(parts[1])
        })
    }()

    static func has(_ encoder: String) -> Bool { encoders.contains(encoder) }
}

enum OutputPath {
    /// Names handed out this session. Jobs run side by side, and one may not have written its file yet.
    @MainActor private static var reserved: Set<String> = []

    /// `dir/base.ext`, or `dir/base 2.ext` and up when that's taken.
    @MainActor static func unique(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || reserved.contains(url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        reserved.insert(url.path)
        return url
    }

    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("morph-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
