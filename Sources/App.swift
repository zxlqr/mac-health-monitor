import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MonitorStore()
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let controller = NSHostingController(rootView: MonitorView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        store.onChange = { [weak self] in self?.updateMenu() }
        store.start()
        updateMenu()
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    private func updateMenu() {
        guard let button = item.button else { return }
        let percent = store.snapshot.score.map { "\(Int($0.rounded()))%" } ?? "—%"
        button.title = percent
        button.image = nil
        button.imagePosition = .noImage
        if store.style == .iconPercent {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        } else if store.style == .compactBar {
            button.image = barImage(score: store.snapshot.score)
            button.imagePosition = .imageLeading
        }
        button.toolTip = "Нагрузка Mac: \(percent). Нажмите для процессора, памяти и диска."
        button.setAccessibilityLabel("Нагрузка Mac \(percent). Показать подробности")
    }

    private func barImage(score: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 13), flipped: false) { _ in
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 15, height: 9), xRadius: 2, yRadius: 2)
            NSColor.labelColor.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            if let score, score > 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 11 * min(score, 100) / 100, height: 5), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func popoverWillShow(_ notification: Notification) { store.setPopoverVisible(true) }
    func popoverDidClose(_ notification: Notification) { store.setPopoverVisible(false) }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

@main
enum MacHealthMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--preview-window") {
            let delegate = PreviewDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }

    private static func runSelfTest() {
        var fixture = MetricsSnapshot.preview
        precondition(fixture.score == 24)
        fixture.pressure = .warning
        precondition(fixture.score == 70)
        fixture.cpu = 95
        precondition(fixture.score == 95)
        fixture.pressure = .critical
        precondition(fixture.score == 100)
        fixture.pressure = .unavailable
        precondition(fixture.score == nil)
        let sampler = SystemSampler()
        precondition(sampler.sample().cpu == nil)
        Thread.sleep(forTimeInterval: 1)
        let actual = sampler.sample()
        guard let cpu = actual.cpu, (0...100).contains(cpu),
              let memory = actual.memoryUsed, memory > 0, memory <= actual.memoryTotal,
              let disk = actual.diskAvailable, disk > 0 else {
            fputs("FAIL: live metric unavailable\n", stderr)
            exit(1)
        }
        let output: [String: Any] = ["result": "PASS", "cpuPercent": cpu,
            "memoryUsedBytes": memory, "memoryTotalBytes": actual.memoryTotal,
            "memoryPressure": actual.pressure.rawValue,
            "diskAvailableBytes": disk, "score": actual.score as Any? ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print(json) }
    }

}


/// A synthetic, timer-free window for visual QA; never touches the installed app.
@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let store = MonitorStore(preview: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        var fixture = MetricsSnapshot.preview
        switch argument("--preview-state") {
        case "warning":
            fixture.cpu = 85
            fixture.memoryUsed = 14_388_133_888
            fixture.pressure = .warning
            fixture.diskAvailable = 42_842_298_778
        case "critical":
            fixture.cpu = 99
            fixture.memoryUsed = 16_320_875_724
            fixture.pressure = .critical
            fixture.diskAvailable = 4_999_631_749
        case "unavailable": fixture = .empty
        case "zero":
            fixture.cpu = 0
            fixture.memoryUsed = 0
            fixture.diskAvailable = fixture.diskTotal
        case "full":
            fixture.cpu = 100
            fixture.memoryUsed = fixture.memoryTotal
            fixture.pressure = .critical
            fixture.diskAvailable = 0
        default: break
        }
        store.snapshot = fixture
        let previewHeight = argument("--preview-height").flatMap(Double.init).map { CGFloat($0) }
        let view = MonitorView(store: store, showsFormula: args.contains("--preview-expanded"), viewportLimit: previewHeight)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Нагрузка Mac — пример данных"
        window.appearance = NSAppearance(named: args.contains("--preview-dark") ? .darkAqua : .aqua)
        window.delegate = self
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        print("PREVIEW_WINDOW_ID=\(window.windowNumber)")
        fflush(stdout)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
