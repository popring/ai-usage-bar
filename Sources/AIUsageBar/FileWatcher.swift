import Foundation

/// Watch one file for changes; callback on the main thread.
///
/// Claude Code writes `~/.claude.json` via atomic replace (temp file + rename),
/// so the old fd receives delete/rename instead of write — after that we must
/// re-open the new file to keep watching. If the file doesn't exist yet (e.g.
/// never logged in), retry periodically.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// The state file is written frequently while Claude Code is active; coalesce
    /// for a second to avoid cascading triggers.
    private static let debounce: TimeInterval = 1
    private static let retryInterval: TimeInterval = 15

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                self?.arm()
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let events = src.data
            self.fire()
            if !events.isDisjoint(with: [.delete, .rename]) {
                self.arm()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
