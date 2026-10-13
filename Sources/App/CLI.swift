import Foundation

// `morph FILE... --to EXT` converts from a terminal, `morph --targets FILE` lists what a file can
// become. The same binary is the app; it runs this instead when it gets either flag.

@MainActor
enum CLI {
    static func wants(_ args: [String]) -> Bool {
        args.contains("--to") || args.contains("--targets") || args.contains("--help") || args.contains("-h")
    }

    static func run(_ args: [String]) async -> Int32 {
        var files: [URL] = [], to: String?, listTargets = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--to":
                i += 1
                guard i < args.count else { return usage() }
                to = Formats.normalize(args[i].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            case "--targets": listTargets = true
            case "-h", "--help": return usage(0)
            default: files.append(URL(fileURLWithPath: args[i]).standardizedFileURL)
            }
            i += 1
        }
        guard !files.isEmpty else { return usage() }

        if listTargets {
            for file in files {
                let src = Formats.normalize(file.pathExtension)
                let targets = Formats.commonTargets(for: [src]).map { t -> String in
                    if case .tool(let tool) = t.need { return "\(t.ext) (\(tool.displayName))" }
                    return t.ext
                }
                print("\(file.lastPathComponent): \(targets.isEmpty ? "nothing" : targets.joined(separator: " "))")
            }
            return 0
        }

        guard let to else { return usage() }
        var status: Int32 = 0
        for file in files {
            do {
                for out in try await Converter.convert(file, to: to) { print(out.path) }
            } catch {
                FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
                status = 1
            }
        }
        return status
    }

    private static func usage(_ status: Int32 = 2) -> Int32 {
        let text = """
        usage: morph FILE... --to EXT     convert, writing next to each file
               morph FILE... --targets    list what each file can become

        """
        FileHandle(fileDescriptor: status == 0 ? 1 : 2).write(Data(text.utf8))
        return status
    }
}
