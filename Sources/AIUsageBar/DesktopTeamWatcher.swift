import Foundation

/// 从 Claude Desktop 自己的 Local Storage 里实时拿「当前选中的 org」。
///
/// 为什么需要它：`~/.claude.json` 的登录态要等 Desktop 内嵌的 Claude Code
/// 重新同步才改写，切 team 后有几十秒级滞后。而 Desktop 是 claude.ai 的网页壳，
/// 切 org 的瞬间就会把 org uuid 写进 localStorage 的 `lastOrganization`，
/// 落到 Chromium leveldb 的当前 `.log` 文件（追加写、未压缩）。
///
/// 这里刻意**不完整解析 leveldb**（表格式 + snappy，又重又脆，文件运行时还会轮转）：
/// 只增量扫 `.log` 新追加的字节，正则抓「最后一次出现的 key + 紧跟的 uuid」当最新值。
/// 历史值被压进 `.ldb` 后扫不到 —— 没关系，拿不到就保持沉默，
/// 由外面的 `~/.claude.json` 慢通道兜底，不会比没有这层更差。
final class DesktopTeamWatcher {

    /// 抓到新的 org uuid 时回调（主线程）。
    private let onOrgChange: (String) -> Void

    /// 最近一次从 leveldb 里抓到的 org uuid；还没抓到过为 nil。
    private(set) var currentOrgUuid: String?

    private let dirURL = AppHome.url
        .appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")

    private var dirWatcher: FileWatcher?
    private var logWatcher: FileWatcher?
    private var logPath: String?
    /// 下次增量扫描的起点。留一小段重叠，防 key 恰好被读取边界劈开。
    private var scanOffset: UInt64 = 0
    private static let overlap: UInt64 = 64

    private static let pattern = try! NSRegularExpression(
        pattern: "lastOrganization.{0,8}?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        options: [.dotMatchesLineSeparators])

    init(onOrgChange: @escaping (String) -> Void) {
        self.onOrgChange = onOrgChange
        // Desktop 没装 / 目录不存在时 FileWatcher 自己会周期重试，这里不用特判。
        dirWatcher = FileWatcher(path: dirURL.path) { [weak self] in
            self?.resolveLog()
        }
        resolveLog(initial: true)
    }

    /// 找当前活跃的 `.log`（leveldb 会轮转文件名）。换了就从头扫，没换就增量扫。
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

    /// 只读上次扫描点之后的新字节。leveldb 的 .log 是纯追加的，
    /// 所以「文件里最后一次出现」就是「最新值」。
    private func scan() {
        guard let logPath,
              let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > scanOffset else {
            // 变小了说明文件被换掉重建（正常轮转走 resolveLog，这里兜个底）。
            if size < scanOffset { scanOffset = 0 }
            return
        }
        try? handle.seek(toOffset: scanOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        scanOffset = size > Self.overlap ? size - Self.overlap : 0

        // latin1 与字节一一对应，不会因为无效 UTF-8 丢内容。
        guard let text = String(data: data, encoding: .isoLatin1) else { return }
        let matches = Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last,
              let range = Range(last.range(at: 1), in: text) else { return }

        let uuid = String(text[range])
        guard uuid != currentOrgUuid else { return }
        currentOrgUuid = uuid
        onOrgChange(uuid)
    }
}
