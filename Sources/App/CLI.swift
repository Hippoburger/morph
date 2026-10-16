import Foundation

// `morph FILE... --to EXT` converts from a terminal, `--smaller` makes files smaller and `--targets`
// lists what a file can become. The same binary is the app; it runs this instead when it gets a flag.

@MainActor
enum CLI {
    static func wants(_ args: [String]) -> Bool {
        args.contains("--to") || args.contains("--smaller") || args.contains("--targets") || args.contains("--help") || args.contains("-h")
    }

    static func run(_ args: [String]) async -> Int32 {
        var files: [URL] = [], to: String?, size: Int?, smaller = false, listTargets = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--to":
                i += 1
                guard i < args.count else { return usage() }
                to = Formats.normalize(args[i].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            case "--size":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else { return usage() }
                size = n
            case "--smaller": smaller = true
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

        guard smaller || to != nil else { return usage() }
        var status: Int32 = 0
        for file in files {
            do {
                let outs = if let to { try await Converter.convert(file, to: to, maxPixels: size) } else { [try await Shrink.run(file)] }
                for out in outs { print(out.path) }
            } catch {
                FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
                status = 1
            }
        }
        return status
    }

    private static func usage(_ status: Int32 = 2) -> Int32 {
        let text = """
        usage: morph FILE... --to EXT [--size PX]   convert, writing next to each file;
                                                  --size fits images within PX pixels
               morph FILE... --smaller            make photos, videos and PDFs smaller
               morph FILE... --targets            list what each file can become

        """
        FileHandle(fileDescriptor: status == 0 ? 1 : 2).write(Data(text.utf8))
        return status
    }
}
