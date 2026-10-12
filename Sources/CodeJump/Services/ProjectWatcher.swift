import CoreServices
import CodeJumpCore
import Foundation

/// FSEvents batches filesystem changes. There is no periodic project scan.
final class ProjectWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "CodeJump.filesystem", qos: .utility)
    private var pending = Set<String>()
    private var pendingWork: DispatchWorkItem?
    private let onChange: @Sendable ([String]) -> Void
    private let roots: [String]

    init(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        self.roots = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
            guard let context else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(context).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            // Judge excluded folders relative to each project root, exactly as scanning does.
            let values = (0..<count).compactMap { array[$0] as? String }.filter { path in
                !ProjectIndex.isIgnoredEvent(path, roots: watcher.roots)
            }
            let mustScan = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            guard mustScan || !values.isEmpty else { return }
            watcher.receive(mustScan ? [] : values)
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
    }

    private func receive(_ paths: [String]) {
        if paths.isEmpty { pending.insert("") } else { pending.formUnion(paths) }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = self.pending.contains("") ? [] : Array(self.pending)
            self.pending.removeAll()
            self.onChange(paths)
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    deinit {
        pendingWork?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
