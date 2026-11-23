import AppKit
import Darwin

struct AppUsage: Identifiable {
    let id: String
    let name: String
    var bundleURL: URL? = nil
    var cpu: Double?
    var memory: UInt64 = 0
}

struct AppRankings {
    var cpu: [AppUsage] = []
    var memory: [AppUsage] = []
    var warmingUp = true

    static let preview: Self = {
        let apps = [
            AppUsage(id: "com.apple.Safari", name: "Safari", cpu: 12.4, memory: 1_846_000_000),
            AppUsage(id: "com.apple.Music", name: "Музыка", cpu: 5.1, memory: 226_000_000),
            AppUsage(id: "com.apple.finder", name: "Finder", cpu: 1.2, memory: 310_000_000)
        ]
        return Self(cpu: apps, memory: [apps[0], apps[2], apps[1]], warmingUp: false)
    }()
}

struct ApplicationOwner {
    let id: String
    let name: String

    let bundleURL: URL

    @MainActor static func running() -> [pid_t: Self] {
        var result: [pid_t: Self] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL, url.pathExtension == "app",
                  app.activationPolicy != .prohibited, let name = app.localizedName else { continue }
            // Nested helper apps are accounted for through their parent.
            guard !url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") }) else { continue }
            result[app.processIdentifier] = Self(id: app.bundleIdentifier ?? url.path, name: name, bundleURL: url)
        }
        return result
    }
}

actor ApplicationSampler {
    private struct Counter {
        let birth: UInt64
        let ticks: UInt64
    }
    private var previous: [pid_t: Counter] = [:]
    private var previousTime: UInt64?

    func sample(owners: [pid_t: ApplicationOwner]) -> AppRankings {
        let now = mach_absolute_time()
        let elapsed = previousTime.map { Double(now - $0) }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        var totals: [String: AppUsage] = [:]
        var counters: [pid_t: Counter] = [:]
        var visited = Set<pid_t>()

        for (root, owner) in owners {
            var pending = [root]
            while let pid = pending.popLast() {
                guard (pid == root || owners[pid] == nil), visited.insert(pid).inserted else { continue }
                pending.append(contentsOf: children(of: pid))
                var info = rusage_info_v0()
                let status = withUnsafeMutablePointer(to: &info) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V0, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                }
                guard status == 0 else { continue }
                let ticks = info.ri_user_time + info.ri_system_time
                counters[pid] = Counter(birth: info.ri_proc_start_abstime, ticks: ticks)
                var usage = totals[owner.id] ?? AppUsage(id: owner.id, name: owner.name, bundleURL: owner.bundleURL)
                usage.memory += info.ri_phys_footprint
                if let old = previous[pid], old.birth == info.ri_proc_start_abstime,
                   ticks >= old.ticks, let elapsed, elapsed > 0 {
                    // rusage CPU counters and mach_absolute_time use the same timebase.
                    usage.cpu = (usage.cpu ?? 0) + 100 * Double(ticks - old.ticks) / elapsed / cores
                }
                totals[owner.id] = usage
            }
        }
        previous = counters
        previousTime = now
        let apps = totals.values.sorted { $0.id < $1.id }
        return AppRankings(
            cpu: Array(apps.filter { $0.cpu != nil }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(3)),
            memory: Array(apps.sorted { $0.memory > $1.memory }.prefix(3)),
            warmingUp: elapsed == nil && !apps.isEmpty
        )
    }

    private func children(of pid: pid_t) -> [pid_t] {
        var capacity = 16
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes {
                proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return [] }
            if count < capacity { return Array(buffer.prefix(Int(count))) }
            capacity *= 2
        }
    }
}
