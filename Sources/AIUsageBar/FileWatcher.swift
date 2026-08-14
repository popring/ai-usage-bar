import Foundation

/// 盯一个文件的变化，回调在主线程。
///
/// Claude Code 写 `~/.claude.json` 是原子替换（写临时文件再 rename 过来），
/// 所以旧 fd 上收到的是 delete/rename 而不是 write —— 收到后必须重新 open
/// 新文件才能继续盯。文件暂时不存在（比如还没登录过）就隔段时间重试。
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// Claude Code 活跃时状态文件写得很勤，攒一秒再处理，避免连环触发。
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
