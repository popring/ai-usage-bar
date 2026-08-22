import Foundation

/// Reads the "currently selected org" live from Claude Desktop's own Local Storage.
///
/// Why: the login state in `~/.claude.json` only rewrites once Desktop's embedded
/// Claude Code re-syncs, lagging tens of seconds after a team switch. Desktop is a
/// claude.ai web shell, so the moment you switch orgs it writes the org uuid into
/// localStorage's `lastOrganization`, which lands in the current Chromium leveldb
/// `.log` file (append-only, uncompressed).
///
/// Deliberately does **not** parse leveldb fully (table format + snappy — heavy,
/// brittle, and the files rotate at runtime): it only incrementally scans newly
/// appended bytes of the `.log` and regex-grabs "last occurrence of the key + the
/// uuid right after it" as the latest value. Historical values compacted into `.ldb`
/// are unreachable — fine: when nothing is found we stay silent and the slow
/// `~/.claude.json` path outside covers it, so this layer never makes things worse.
final class DesktopTeamWatcher {

    /// Called (on the main thread) when a new org uuid is captured.
    private let onOrgChange: (String) -> Void

    /// Most recent org uuid grabbed from leveldb; nil until one is captured.
    private(set) var currentOrgUuid: String?

    /// When this uuid hit disk (the .log's mtime). The follow logic compares it with
    /// cswap's lastSwitchAt — a stale value scanned from history at startup must not
    /// override a switch that just happened.
    private(set) var currentOrgAt: Date?

    private let dirURL = AppHome.url
        .appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")

    private var dirWatcher: FileWatcher?
    private var logWatcher: FileWatcher?
    private var logPath: String?
    /// Start of the next incremental scan. Keep a small overlap so a key can't be
    /// split across a read boundary.
    private var scanOffset: UInt64 = 0
    private static let overlap: UInt64 = 64

    private static let pattern = try! NSRegularExpression(
        pattern: "lastOrganization.{0,8}?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        options: [.dotMatchesLineSeparators])

    init(onOrgChange: @escaping (String) -> Void) {
        self.onOrgChange = onOrgChange
        // If Desktop isn't installed / the dir doesn't exist, FileWatcher retries
        // periodically on its own — no special-casing needed here.
        dirWatcher = FileWatcher(path: dirURL.path) { [weak self] in
            self?.resolveLog()
        }
        resolveLog(initial: true)
    }

    /// Find the currently active `.log` (leveldb rotates file names). New file:
    /// scan from the start; same file: scan incrementally.
    private func resolveLog(initial: Bool = false) {
        let fm = FileManager.default
        let logs = ((try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
        let newest = logs.max { a, b in
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma < mb
        }
        guard let newest else { return }

        if newest.path != logPath {
            logPath = newest.path
            scanOffset = 0
            logWatcher = FileWatcher(path: newest.path) { [weak self] in
                self?.scan()
            }
        }
        scan()
    }

    /// Read only the bytes appended since the last scan. leveldb's .log is
    /// append-only, so "last occurrence in the file" equals "latest value".
    private func scan() {
        guard let logPath,
              let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > scanOffset else {
            // Shrunk: the file was replaced/recreated (normal rotation goes through
            // resolveLog; this is a safety net).
            if size < scanOffset { scanOffset = 0 }
            return
        }
        try? handle.seek(toOffset: scanOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        scanOffset = size > Self.overlap ? size - Self.overlap : 0

        // latin1 maps bytes 1:1, so invalid UTF-8 can't drop content.
        guard let text = String(data: data, encoding: .isoLatin1) else { return }
        let matches = Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last,
              let range = Range(last.range(at: 1), in: text) else { return }

        let uuid = String(text[range])
        guard uuid != currentOrgUuid else { return }
        currentOrgUuid = uuid
        currentOrgAt = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date ?? Date()
        onOrgChange(uuid)
    }
}
