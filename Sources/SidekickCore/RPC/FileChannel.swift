import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Browse the host's filesystem from a client and copy files in either
/// direction. v0 surface is intentionally small — list, read, write — so a
/// phone can pull a file off the host's Downloads folder or push one back
/// without a SMB share.
public enum FileChannel {
    /// One file or directory in a listing.
    public struct Entry: Codable, Sendable, Hashable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date

        public init(name: String, isDirectory: Bool, size: Int64, modified: Date) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modified = modified
        }
    }

    public struct Message: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case list, listResult
            case read, readResult
            case write, writeAck
            case openInFinder
        }
        public var kind: Kind
        /// Path relative to the host's home dir, expanded server-side.
        public var path: String?
        public var entries: [Entry]?
        public var data: Data?      // base64 in JSON; fine until we wire binary frames
        public var error: String?

        public init(kind: Kind, path: String? = nil, entries: [Entry]? = nil, data: Data? = nil, error: String? = nil) {
            self.kind = kind
            self.path = path
            self.entries = entries
            self.data = data
            self.error = error
        }
    }
}

/// Host-side adapter. Resolves paths under the user's home dir, enforces a
/// simple "no escaping ~" check, and answers list/read/write.
public final class FileHostAdapter: @unchecked Sendable {

    private let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = root
    }

    public func handle(_ message: FileChannel.Message) async -> FileChannel.Message {
        switch message.kind {
        case .list:        return list(path: message.path ?? "")
        case .read:        return read(path: message.path ?? "")
        case .write:       return write(path: message.path ?? "", data: message.data ?? Data())
        case .openInFinder:
            // Native side-effect, no body to return.
            if let p = message.path, let url = resolve(p) {
                NSWorkspaceWrapper.activateFileViewerSelecting([url])
            }
            return .init(kind: .writeAck)
        default:
            return .init(kind: .writeAck, error: "Unknown kind")
        }
    }

    // MARK: - Internals

    private func resolve(_ path: String) -> URL? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        // Refuse anything that escapes the home dir.
        guard url.path.hasPrefix(root.path) else { return nil }
        return url
    }

    private func list(path: String) -> FileChannel.Message {
        guard let url = resolve(path) else { return .init(kind: .listResult, error: "Bad path") }
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
            let entries: [FileChannel.Entry] = contents.map { item in
                let r = try? item.resourceValues(forKeys: Set(keys))
                return .init(
                    name: item.lastPathComponent,
                    isDirectory: r?.isDirectory ?? false,
                    size: Int64(r?.fileSize ?? 0),
                    modified: r?.contentModificationDate ?? .distantPast
                )
            }
            return .init(kind: .listResult, path: path, entries: entries.sorted { $0.name < $1.name })
        } catch {
            return .init(kind: .listResult, path: path, error: "\(error)")
        }
    }

    private func read(path: String) -> FileChannel.Message {
        guard let url = resolve(path) else { return .init(kind: .readResult, error: "Bad path") }
        do {
            let data = try Data(contentsOf: url)
            return .init(kind: .readResult, path: path, data: data)
        } catch {
            return .init(kind: .readResult, path: path, error: "\(error)")
        }
    }

    private func write(path: String, data: Data) -> FileChannel.Message {
        guard let url = resolve(path) else { return .init(kind: .writeAck, error: "Bad path") }
        do {
            try data.write(to: url, options: .atomic)
            return .init(kind: .writeAck, path: path)
        } catch {
            return .init(kind: .writeAck, path: path, error: "\(error)")
        }
    }
}

/// Trampoline around `NSWorkspace` so iOS builds (which don't have AppKit)
/// can still link the rest of the channel — only the Mac host actually
/// reveals files in Finder.
private enum NSWorkspaceWrapper {
    static func activateFileViewerSelecting(_ urls: [URL]) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        #endif
    }
}
