import AppKit

/// What a single change of the pasteboard yielded, before it becomes a `ClipEntry`.
enum CapturedContent: Equatable {
    case text(String)
    case image(Data)
    case files([URL])
}

/// Classifies pasteboard content and turns it into a `ClipEntry`. Pure: the
/// watcher reads the pasteboard once per change and hands the raw values here,
/// so the rules are testable without touching the real pasteboard.
enum ClipboardCapture {
    /// A single image above this size is skipped silently.
    static let imageByteLimit = 8 * 1024 * 1024
    /// Placeholder value for image entries; it is not the image's content.
    static let imageValue = "[image]"
    /// File entries render as `[file] <name>`; the value carries the name.
    static let fileValuePrefix = "[file]"

    /// The one read of a pasteboard: text first, then an image, then file URLs.
    /// Shared by the watcher's poll and the cut-recovery paths, so a late cut
    /// recovers as the same entry type the watcher would have filed.
    static func read(_ pasteboard: NSPasteboard = .general) -> CapturedContent? {
        let text = pasteboard.string(forType: .string)
        // Only touch the (potentially large) image data when there is no text.
        let hasText = text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let png = hasText ? nil : pasteboard.data(forType: .png)
        let tiff = (hasText || png != nil) ? nil : pasteboard.data(forType: .tiff)
        let fileStrings = hasText || png != nil || tiff != nil
            ? []
            : (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
        return classify(text: text, png: png, tiff: tiff, fileURLStrings: fileStrings)
    }

    /// Priority: non-empty text, else a PNG (converting TIFF), else file URLs.
    /// Returns nil when none applies.
    static func classify(
        text: String?,
        png: Data?,
        tiff: Data?,
        fileURLStrings: [String]
    ) -> CapturedContent? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        if let data = pngImage(png: png, tiff: tiff) {
            return .image(data)
        }
        let urls = fileURLStrings.compactMap { URL(string: $0) }.filter(\.isFileURL)
        return urls.isEmpty ? nil : .files(urls)
    }

    /// PNG as-is, or TIFF converted to PNG. nil when neither is present, the
    /// TIFF cannot be decoded, or the bytes exceed `imageByteLimit`.
    static func pngImage(png: Data?, tiff: Data?) -> Data? {
        if let png { return png.count <= imageByteLimit ? png : nil }
        guard let tiff, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        return data.count <= imageByteLimit ? data : nil
    }

    /// Builds the history entry for a captured pasteboard change.
    /// Copied files are stored as URLs only; a moved file becomes a dead
    /// reference, which is accepted for a history that never touches disk.
    static func entry(for captured: CapturedContent, source: String?) -> ClipEntry {
        switch captured {
        case .text(let text):
            return ClipEntry(value: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        case .image(let data):
            return ClipEntry(value: imageValue, source: source, image: data)
        case .files(let urls):
            let name = urls.first?.lastPathComponent ?? ""
            let value = name.isEmpty ? fileValuePrefix : "\(fileValuePrefix) \(name)"
            return ClipEntry(value: value, source: source, fileURLs: urls)
        }
    }
}
