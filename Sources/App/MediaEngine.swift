import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Video and audio. AVFoundation handles MP4 and MOV and afconvert the audio formats Core Audio can
// encode (WAV, FLAC, AAC, M4A). Everything else, and anything the native path fails on, goes through
// ffmpeg when it's installed.

enum MediaEngine {
    static func convert(_ input: URL, from src: String, to dst: String, out: URL) async throws {
        if Formats.need(from: src, to: dst) == .native {
            do {
                try await native(input, from: src, to: dst, out: out)
                return
            } catch {
                // Core Audio reads Ogg and Opus only sometimes, and passthrough exports trip on odd codecs.
                guard Tool.ffmpeg.path != nil else { throw error }
                try? FileManager.default.removeItem(at: out)
            }
        }
        guard let ffmpeg = Tool.ffmpeg.path else { throw MissingToolError(tool: .ffmpeg) }
        let kind = Formats.kind(of: src)
        try await Task.detached {
            _ = try Shell.run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path] + ffmpegArgs(to: dst, fromVideo: kind == .video) + [out.path])
        }.value
    }

    private static func ffmpegArgs(to dst: String, fromVideo: Bool) -> [String] {
        switch dst {
        case "mp4": return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov": return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "mkv": return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "192k"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "2"]
        case "gif": return ["-vf", "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "aac": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "6"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        default: return []
        }
    }

    // MARK: Native

    private static func native(_ input: URL, from src: String, to dst: String, out: URL) async throws {
        switch (Formats.kind(of: src), Formats.kind(of: dst)) {
        case (.video, .video):
            try await export(AVURLAsset(url: input), to: out, type: dst == "mov" ? .mov : .mp4,
                             presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        case (.video, .audio):
            let asset = AVURLAsset(url: input)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ConversionError("This video has no sound.") }
            let m4a = dst == "m4a" ? out : OutputPath.temporary(ext: "m4a")
            try await export(asset, to: m4a, type: .m4a, presets: [AVAssetExportPresetAppleM4A])
            if m4a != out {
                defer { try? FileManager.default.removeItem(at: m4a) }
                try await afconvert(m4a, to: dst, out: out)
            }
        case (.video, .image):
            try await gif(from: input, to: out)
        default:
            try await afconvert(input, to: dst, out: out)
        }
    }

    private static func export(_ asset: AVURLAsset, to out: URL, type: AVFileType, presets: [String]) async throws {
        var lastError: Error = ConversionError("Couldn't export the file.")
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            do {
                try await session.export(to: out, as: type)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw lastError
    }

    private static func afconvert(_ input: URL, to dst: String, out: URL) async throws {
        let attempts: [[String]]
        // AAC at a high variable bitrate first; Core Audio refuses that for some sources, and its
        // defaults then. A fixed bitrate is refused for more of them still.
        let vbr = ["-s", "3", "-u", "vbrq", "110"]
        switch dst {
        case "wav": attempts = [["-f", "WAVE", "-d", "LEI16"]]
        case "flac": attempts = [["-f", "flac", "-d", "flac"]]
        case "aac": attempts = [["-f", "adts", "-d", "aac"] + vbr, ["-f", "adts", "-d", "aac"]]
        case "m4a": attempts = [["-f", "m4af", "-d", "aac"] + vbr, ["-f", "m4af", "-d", "aac"]]
        default: throw ConversionError("Core Audio can't write \(dst.uppercased()).")
        }
        var lastError: Error?
        for format in attempts {
            do {
                try await Task.detached { _ = try Shell.run("/usr/bin/afconvert", format + [input.path, out.path]) }.value
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw lastError!
    }

    /// 10 frames a second, at most 480 pixels wide, for at most a minute.
    private static func gif(from input: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: input)
        let seconds = try await asset.load(.duration).seconds
        let fps = 10.0
        let count = max(1, min(Int(seconds * fps), 600))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError("Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(dest, image, frame)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't read any frames from the video.") }
    }
}
