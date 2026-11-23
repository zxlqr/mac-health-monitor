import AppKit
import SwiftUI

/// Every bar increases from left to right. Unknown values are never drawn as zero.
struct MonitorView: View {
    @ObservedObject var store: MonitorStore
    @State var showsFormula = false
    @State var showsSettings = false
    var viewportLimit: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var supportingColor: Color { Color.primary.opacity(0.72) }
    private var snapshot: MetricsSnapshot { store.snapshot }
    private var score: String { percentage(snapshot.score) }
    private var availableHeight: CGFloat { max(260, viewportLimit ?? ((NSScreen.main?.visibleFrame.height ?? 800) - 90)) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { panel }
                .frame(height: availableHeight)
        }
        .frame(width: 380)
        .frame(maxHeight: availableHeight, alignment: .top)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Нагрузка Mac").font(.headline)
                Spacer()
                Text(score).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Общая нагрузка Mac")
            .accessibilityValue(snapshot.score.map { "\(Int($0.rounded())) процентов. \(summary)" } ?? summary)
            Text(summary).font(.subheadline).foregroundStyle(statusColor(overallStatus))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            meter(snapshot.score, title: "Общая нагрузка", status: overallStatus)
                .padding(.top, 9)
            HStack {
                Text("0 · низкая")
                Spacer()
                Text("100 · высокая")
            }
            .font(.caption).foregroundStyle(supportingColor).padding(.top, 4)
            .accessibilityHidden(true)

            Toggle(isOn: $store.detailed) {
                Text("Подробный режим")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .font(.subheadline)
            .padding(.top, 12)

            Divider().padding(.vertical, 13)
            metricHeader("Процессор", symbol: "cpu", value: percentage(snapshot.cpu))
            meter(snapshot.cpu, title: "Загрузка процессора", status: cpuStatus).padding(.top, 7)
            detail(snapshot.cpu == nil ? "Собираем измерение CPU…" : "\(cpuStatus.title) · доля всех ядер")

            if store.detailed {
                ranking("Больше всего нагружают CPU", apps: store.rankings.cpu,
                        empty: store.rankings.warmingUp ? "Первое измерение…" : "Нет данных") {
                    String(format: "%.1f%%", locale: Locale(identifier: "ru_RU"), $0.cpu ?? 0)
                }
            }

            Divider().padding(.vertical, 12)
            metricHeader("Оперативная память", symbol: "memorychip", value: occupiedPercentage(memoryPercent))
            meter(memoryPercent, title: "Занято оперативной памяти", status: memoryStatus).padding(.top, 7)
            detail(memoryDetail)
                .help("Приближённо: непуржируемые анонимные страницы + wired + сжатая память. Файловый кэш не считается занятой памятью.")
            HStack(spacing: 4) {
                Text("Давление:").foregroundStyle(supportingColor)
                Text(snapshot.pressure.title).foregroundStyle(statusColor(memoryStatus))
            }
            .font(.caption).padding(.top, 3)
            .accessibilityElement(children: .combine)

            if store.detailed {
                ranking("Больше всего занимают памяти", apps: store.rankings.memory,
                        empty: store.rankings.warmingUp ? "Первое измерение…" : "Нет данных") {
                    $0.memory >= 1_073_741_824 ? bytes($0.memory) : "\(Int((Double($0.memory) / 1_048_576).rounded())) МиБ"
                }
            }

            Divider().padding(.vertical, 12)
            metricHeader("Хранилище", symbol: "internaldrive", value: occupiedPercentage(diskPercent))
            meter(diskPercent, title: "Занято на домашнем томе", status: diskStatus).padding(.top, 7)
            detail(diskDetail)
            Text(diskStatus == .warning || diskStatus == .critical ? "Мало места · не влияет на нагрузку" : "Домашний том · не влияет на нагрузку")
                .font(.caption).foregroundStyle(statusColor(diskStatus == .normal ? .unavailable : diskStatus))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            Text("Шкалы CPU, памяти и диска: 0–100%, слева направо.")
                .font(.caption2).foregroundStyle(supportingColor)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 9)

            Divider().padding(.vertical, 13)
            DisclosureGroup("Как считается нагрузка", isExpanded: $showsFormula) {
                Text("Максимум из загрузки CPU и оценки давления памяти: нормальное — 0, повышенное — 70, критическое — 100. Процент занятой ОЗУ и диск в оценку не входят. Это ориентир, а не диагноз. Если давление памяти недоступно, общая оценка не выводится.")
                    .font(.caption).foregroundStyle(supportingColor)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            .font(.subheadline)
            .padding(.bottom, 13)

            DisclosureGroup("Настройки", isExpanded: $showsSettings) {
                settings
                    .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding(18)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("В строке меню").font(.subheadline)
                    Picker("В строке меню", selection: $store.style) {
                        ForEach(MenuStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("Обновление").font(.subheadline)
                    Picker("Обновление", selection: $store.interval) {
                        ForEach(MonitorStore.intervals, id: \.self) { Text("Раз в \(Int($0)) с").tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 13)
            HStack {
                Text(store.isPreview ? "Пример данных · без опроса Mac" : "Диск обновляется раз в минуту")
                    .font(.caption2).foregroundStyle(supportingColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Выйти") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }

    private func ranking(_ title: String, apps: [AppUsage], empty: String,
                         value: @escaping (AppUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(supportingColor)
            if apps.isEmpty { Text(empty).foregroundStyle(supportingColor) }
            ForEach(apps) { app in
                HStack(spacing: 6) {
                    AppIcon(app: app)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(app.name).lineLimit(1).help(app.name)
                    Spacer(minLength: 8)
                    Text(value(app)).monospacedDigit().fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
        .padding(.top, 8)
    }

    private func metricHeader(_ title: String, symbol: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 17).foregroundStyle(supportingColor).accessibilityHidden(true)
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(supportingColor)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
    }

    private func meter(_ percent: Double?, title: String, status: MeterStatus) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.17 : 0.10))
                if let percent {
                    Capsule().fill(statusColor(status))
                        .frame(width: geometry.size.width * max(0, min(100, percent)) / 100)
                } else {
                    // A dash in the track distinguishes missing data from a measured 0%.
                    Text("—").font(.system(size: 9, weight: .bold)).foregroundStyle(supportingColor)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent.map { "\(Int($0.rounded())) процентов из 100" } ?? "Данные недоступны")
    }

    private enum MeterStatus {
        case normal, busy, warning, critical, unavailable
        var title: String {
            switch self {
            case .normal: return "Низкая загрузка"
            case .busy: return "Умеренная загрузка"
            case .warning: return "Высокая загрузка"
            case .critical: return "Очень высокая загрузка"
            case .unavailable: return "Нет данных"
            }
        }
    }

    // Semantic states have explicit light/dark variants, with text contrast in both.
    private func statusColor(_ status: MeterStatus) -> Color {
        let dark = colorScheme == .dark
        switch status {
        case .normal: return dark ? Color(red: 0.39, green: 0.85, blue: 0.57) : Color(red: 0.12, green: 0.43, blue: 0.24)
        case .busy: return dark ? Color(red: 0.42, green: 0.74, blue: 1) : Color(red: 0.12, green: 0.38, blue: 0.65)
        case .warning: return dark ? Color(red: 1, green: 0.73, blue: 0.34) : Color(red: 0.57, green: 0.30, blue: 0.03)
        case .critical: return dark ? Color(red: 1, green: 0.48, blue: 0.47) : Color(red: 0.70, green: 0.15, blue: 0.15)
        case .unavailable: return supportingColor
        }
    }

    private func loadStatus(_ percent: Double?) -> MeterStatus {
        guard let percent else { return .unavailable }
        if percent >= 95 { return .critical }
        if percent >= 85 { return .warning }
        if percent >= 50 { return .busy }
        return .normal
    }
    private var overallStatus: MeterStatus {
        guard snapshot.score != nil else { return .unavailable }
        if snapshot.pressure == .critical { return .critical }
        if snapshot.pressure == .warning { return .warning }
        return loadStatus(snapshot.score)
    }
    private var cpuStatus: MeterStatus { loadStatus(snapshot.cpu) }
    private var memoryStatus: MeterStatus {
        guard memoryPercent != nil else { return .unavailable }
        switch snapshot.pressure {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .unavailable: return .unavailable
        }
    }
    private var diskStatus: MeterStatus {
        guard let percent = diskPercent else { return .unavailable }
        if percent > 95 { return .critical }
        if percent > 90 { return .warning }
        return .normal
    }
    private var summary: String {
        guard snapshot.score != nil else {
            return snapshot.pressure == .unavailable ? "Нет оценки: давление памяти недоступно" : "Собираем первое измерение CPU"
        }
        if snapshot.pressure == .critical { return "Критическое давление памяти" }
        if snapshot.pressure == .warning { return "Повышенное давление памяти" }
        return "\(cpuStatus.title) процессора"
    }
    private var memoryPercent: Double? {
        guard let used = snapshot.memoryUsed, snapshot.memoryTotal > 0 else { return nil }
        return 100 * Double(min(used, snapshot.memoryTotal)) / Double(snapshot.memoryTotal)
    }
    private var diskPercent: Double? {
        guard let free = snapshot.diskAvailable, let total = snapshot.diskTotal, total > 0, free <= total else { return nil }
        return 100 * Double(total - free) / Double(total)
    }
    private var memoryDetail: String {
        guard let used = snapshot.memoryUsed, snapshot.memoryTotal > 0 else { return "Объём памяти недоступен" }
        return "Занято \(bytes(used)) из \(bytes(snapshot.memoryTotal))"
    }
    private var diskDetail: String {
        guard diskPercent != nil, let free = snapshot.diskAvailable, let total = snapshot.diskTotal else { return "Объём диска недоступен" }
        return "Свободно \(bytes(free)) из \(bytes(total))"
    }
    private func percentage(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private func occupiedPercentage(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))% занято" } ?? "Нет данных" }
    private func bytes(_ value: UInt64) -> String {
        String(format: "%.1f ГиБ", locale: Locale(identifier: "ru_RU"), Double(value) / 1_073_741_824)
    }
}

/// Keep icon lookups off the metric refresh path. Both rankings share the cache.
@MainActor
private struct AppIcon: View {
    let app: AppUsage
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private var icon: NSImage? {
        let key = (app.bundleURL?.path ?? app.id) as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let url = app.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache.setObject(image, forKey: key)
        return image
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
