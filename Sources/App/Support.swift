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
    /// Runs a tool to completion and returns its output; throws with the last lines of it on failure.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
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

enum OutputPath {
    /// `dir/base.ext`, or `dir/base 2.ext` and up when that's taken.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("morph-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
