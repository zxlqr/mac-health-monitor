import Foundation
import Darwin

enum MemoryPressure: String, Codable {
    case normal, warning, critical, unavailable
    var title: String {
        switch self {
        case .normal: return "Нормальное"
        case .warning: return "Повышенное"
        case .critical: return "Критическое"
        case .unavailable: return "Недоступно"
        }
    }
    var score: Double? {
        switch self {
        case .normal: return 0
        case .warning: return 70
        case .critical: return 100
        case .unavailable: return nil
        }
    }
    static func read() -> Self {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unavailable }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unavailable
        }
    }
}

struct MetricsSnapshot {
    var cpu: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64
    var pressure: MemoryPressure
    var diskAvailable: UInt64?
    var diskTotal: UInt64?
    var sampledAt: Date
    var diskSampledAt: Date?
    var score: Double? {
        guard let cpu, let pressureScore = pressure.score else { return nil }
        return max(min(max(cpu, 0), 100), pressureScore)
    }
    static let empty = MetricsSnapshot(cpu: nil, memoryUsed: nil,
        memoryTotal: ProcessInfo.processInfo.physicalMemory, pressure: .unavailable,
        diskAvailable: nil, diskTotal: nil, sampledAt: Date(), diskSampledAt: nil)
    static let preview = MetricsSnapshot(cpu: 24, memoryUsed: 10_200_547_328,
        memoryTotal: 17_179_869_184, pressure: .normal, diskAvailable: 148_176_371_712,
        diskTotal: 499_963_174_912, sampledAt: Date(), diskSampledAt: Date())
}

/// Only aggregate counters: no process list, file scan, shell command or network.
final class SystemSampler {
    private let host = mach_host_self()
    private var previousCPU: [UInt32]?
    private var lastDiskRead: Date?
    private var diskAvailable: UInt64?
    private var diskTotal: UInt64?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func resetCPU() { previousCPU = nil }

    func sample(forceDisk: Bool = false) -> MetricsSnapshot {
        let now = Date()
        let cpu = readCPU()
        let memory = readMemory()
        if forceDisk || lastDiskRead == nil || now.timeIntervalSince(lastDiskRead!) >= 60 {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
            if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
               let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity {
                diskAvailable = UInt64(max(0, available))
                diskTotal = UInt64(max(0, total))
            } else {
                diskAvailable = nil
                diskTotal = nil
            }
            lastDiskRead = now
        }
        return MetricsSnapshot(cpu: cpu, memoryUsed: memory, memoryTotal: ProcessInfo.processInfo.physicalMemory,
            pressure: MemoryPressure.read(), diskAvailable: diskAvailable, diskTotal: diskTotal,
            sampledAt: now, diskSampledAt: lastDiskRead)
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { previousCPU = nil; return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousCPU = ticks }
        guard let previousCPU else { return nil }
        let deltas = zip(ticks, previousCPU).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        return 100 * Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total)
    }

    private func readMemory() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let anonymous = UInt64(info.internal_page_count)
        let purgeable = UInt64(info.purgeable_count)
        let pages = (anonymous > purgeable ? anonymous - purgeable : 0)
            + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return min(pages * UInt64(pageSize), ProcessInfo.processInfo.physicalMemory)
    }
}
