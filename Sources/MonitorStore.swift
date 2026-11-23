import AppKit
import Combine

enum MenuStyle: String, CaseIterable, Identifiable {
    case percent, iconPercent, compactBar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: return "Только процент"
        case .iconPercent: return "Значок и процент"
        case .compactBar: return "Шкала и процент"
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var snapshot: MetricsSnapshot = .empty
    @Published private(set) var rankings = AppRankings()
    private var rankingTask: Task<Void, Never>?
    private var popoverVisible = false
    @Published var detailed: Bool {
        didSet {
            guard !isPreview else { return }
            UserDefaults.standard.set(detailed, forKey: "detailedView")
            updateRankingTask()
        }
    }
    @Published var style: MenuStyle {
        didSet {
            if !isPreview { UserDefaults.standard.set(style.rawValue, forKey: "menuStyle") }
            onChange?()
        }
    }
    @Published var interval: Double {
        didSet {
            if !isPreview { UserDefaults.standard.set(interval, forKey: "sampleInterval") }
            if running { scheduleTimer() }
            updateRankingTask()
        }
    }
    let isPreview: Bool
    var onChange: (() -> Void)?
    private let sampler = SystemSampler()
    private var timer: Timer?
    private var startupTimer: Timer?
    private var running = false
    private var workspaceObservers: [NSObjectProtocol] = []
    static let intervals: [Double] = [2, 5, 10, 30]

    init(preview: Bool = false) {
        isPreview = preview
        detailed = preview || UserDefaults.standard.bool(forKey: "detailedView")
        style = MenuStyle(rawValue: UserDefaults.standard.string(forKey: "menuStyle") ?? "") ?? .percent
        let savedInterval = UserDefaults.standard.double(forKey: "sampleInterval")
        interval = Self.intervals.contains(savedInterval) ? savedInterval : 5
        if preview { snapshot = .preview; rankings = .preview }
    }

    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        updateRankingTask()
    }

    private func cancelRankings() {
        rankingTask?.cancel()
        rankingTask = nil
    }

    private func updateRankingTask() {
        cancelRankings()
        guard !isPreview, running, popoverVisible, detailed else { return }
        rankings = AppRankings()
        let sampler = ApplicationSampler()
        rankingTask = Task {
            var first = true
            while !Task.isCancelled {
                let next = await sampler.sample(owners: ApplicationOwner.running())
                guard !Task.isCancelled else { return }
                rankings = next
                let delay = first ? 1.0 : interval
                first = false
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func start() {
        guard !isPreview, !running else { return }
        running = true
        refresh(forceDisk: true)
        scheduleTimer()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterWake() }
        })
    }

    func stop() {
        setPopoverVisible(false)
        running = false
        timer?.invalidate()
        startupTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private func pauseForSleep() {
        cancelRankings()
        timer?.invalidate()
        startupTimer?.invalidate()
        sampler.resetCPU()
    }

    private func resumeAfterWake() {
        updateRankingTask()
        sampler.resetCPU()
        refresh(forceDisk: true)
        scheduleTimer()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval * 0.2
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh(forceDisk: Bool = false) {
        snapshot = sampler.sample(forceDisk: forceDisk)
        onChange?()
    }
}
