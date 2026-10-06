import Cocoa
import ServiceManagement

private let host = mach_host_self()

// MARK: - CPU

final class CPUMonitor {
    private var prevTotal: [UInt32]?
    private var prevCores: [[UInt32]] = []

    private(set) var usage = 0.0   // 0...1
    private(set) var user = 0.0
    private(set) var system = 0.0
    private(set) var cores: [Double] = []

    /// Converts tick deltas (user, system, idle, nice) into (busy, user, system) fractions.
    private static func fractions(_ now: [UInt32], _ before: [UInt32]) -> (Double, Double, Double) {
        let d = zip(now, before).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return (0, 0, 0) }
        let user = (d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]) / total
        let system = d[Int(CPU_STATE_SYSTEM)] / total
        return (user + system, user, system)
    }

    func update() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let t = info.cpu_ticks
            let now = [t.0, t.1, t.2, t.3]
            if let prev = prevTotal { (usage, user, system) = Self.fractions(now, prev) }
            prevTotal = now
        }

        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let arr = infoArray else { return }
        var ticks: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: arr[base + $0]) })
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr),
                      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        if prevCores.count == ticks.count {
            cores = zip(ticks, prevCores).map { Self.fractions($0, $1).0 }
        }
        prevCores = ticks
    }
}

// MARK: - Memory

final class MemoryMonitor {
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    private(set) var app = 0.0
    private(set) var wired = 0.0
    private(set) var compressed = 0.0
    private(set) var cached = 0.0
    private(set) var swapUsed = 0.0
    private(set) var pressureLevel: Int32 = 1

    var used: Double { app + wired + compressed }
    var available: Double { max(total - used, 0) }
    var usage: Double { min(used / total, 1) }

    func update() {
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = Double(pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Same formula Activity Monitor uses for "Memory Used".
            app = Double(stats.internal_page_count &- stats.purgeable_count) * page
            wired = Double(stats.wire_count) * page
            compressed = Double(stats.compressor_page_count) * page
            cached = Double(stats.external_page_count &+ stats.purgeable_count) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = Double(swap.xsu_used) }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { pressureLevel = level }
    }
}

// MARK: - Drawing helpers

func levelColor(_ v: Double) -> NSColor {
    v < 0.6 ? .systemGreen : v < 0.85 ? .systemOrange : .systemRed
}

func drawBar(in rect: NSRect, value: Double, color: NSColor) {
    let radius = min(rect.height, rect.width) / 2
    NSColor.labelColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    let v = min(max(value, 0), 1)
    guard v > 0 else { return }
    var fill = rect
    if rect.width >= rect.height { fill.size.width = max(rect.width * v, rect.height) }
    else { fill.size.height = max(rect.height * v, rect.width) }
    color.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
}

func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

/// A meter row for the dropdown menu: title, percentage, big bar and a detail line.
final class MeterView: NSView {
    var title = ""
    var value = 0.0
    var detail = ""

    override var isFlipped: Bool { true }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 16
        let w = bounds.width - pad * 2
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                          .foregroundColor: NSColor.labelColor]
        title.draw(at: NSPoint(x: pad, y: 6), withAttributes: titleAttrs)

        let pct = String(format: "%.0f%%", value * 100)
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: levelColor(value)]
        let pctSize = pct.size(withAttributes: pctAttrs)
        pct.draw(at: NSPoint(x: pad + w - pctSize.width, y: 6), withAttributes: pctAttrs)

        drawBar(in: NSRect(x: pad, y: 26, width: w, height: 8), value: value, color: levelColor(value))

        let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                           .foregroundColor: NSColor.secondaryLabelColor]
        detail.draw(at: NSPoint(x: pad, y: 39), withAttributes: detailAttrs)
    }
}

/// A row of small vertical bars, one per CPU core.
final class CoresView: NSView {
    var cores: [Double] = []

    override var isFlipped: Bool { true }

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 62)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 16
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        "Per core".draw(at: NSPoint(x: pad, y: 0), withAttributes: attrs)
        guard !cores.isEmpty else { return }
        let gap: CGFloat = 4
        let w = (bounds.width - pad * 2 - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
        for (i, v) in cores.enumerated() {
            let x = pad + CGFloat(i) * (w + gap)
            // Vertical bars fill from the bottom: draw in an unflipped sense by inverting.
            let track = NSRect(x: x, y: 18, width: w, height: 36)
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let h = track.height * min(max(v, 0), 1)
            if h > 0 {
                levelColor(v).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: track.maxY - h, width: w, height: h),
                             xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cpu = CPUMonitor()
    private let mem = MemoryMonitor()

    private let cpuView = MeterView(title: "CPU")
    private let coresView = CoresView()
    private let memView = MeterView(title: "Memory (RAM)")
    private let appItem = NSMenuItem()
    private let wiredItem = NSMenuItem()
    private let compressedItem = NSMenuItem()
    private let cachedItem = NSMenuItem()
    private let swapItem = NSMenuItem()
    private let pressureItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        cpu.update()
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common) // keep updating while the menu is open
    }

    private func buildMenu() {
        let menu = NSMenu()
        func viewItem(_ v: NSView) {
            let item = NSMenuItem()
            item.view = v
            menu.addItem(item)
        }
        viewItem(cpuView)
        viewItem(coresView)
        menu.addItem(.separator())
        viewItem(memView)
        for item in [appItem, wiredItem, compressedItem, cachedItem, swapItem, pressureItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let activity = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit SysMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refresh() {
        cpu.update()
        mem.update()

        statusItem.button?.image = statusImage(cpu: cpu.usage, ram: mem.usage)

        cpuView.value = cpu.usage
        cpuView.detail = String(format: "User %.0f%%  ·  System %.0f%%  ·  Idle %.0f%%",
                                cpu.user * 100, cpu.system * 100, (1 - cpu.usage) * 100)
        coresView.cores = cpu.cores
        memView.value = mem.usage
        memView.detail = "\(gb(mem.used)) used of \(gb(mem.total))  ·  \(gb(mem.available)) available"
        [cpuView, coresView, memView].forEach { $0.needsDisplay = true }

        appItem.title = "    App memory:  \(gb(mem.app))"
        wiredItem.title = "    Wired:  \(gb(mem.wired))"
        compressedItem.title = "    Compressed:  \(gb(mem.compressed))"
        cachedItem.title = "    Cached files:  \(gb(mem.cached))"
        swapItem.title = "    Swap used:  \(gb(mem.swapUsed))"
        let pressure: String
        switch mem.pressureLevel {
        case 4: pressure = "🔴 Critical"
        case 2: pressure = "🟠 Warning"
        default: pressure = "🟢 Normal"
        }
        pressureItem.title = "    Memory pressure:  \(pressure)"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Menu bar image: "CPU [bar] 23%   RAM [bar] 68%".
    private func statusImage(cpu: Double, ram: Double) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let barW: CGFloat = 28, labelW: CGFloat = 22, pctW: CGFloat = 30, gap: CGFloat = 8
        let meterW = labelW + barW + 4 + pctW
        let size = NSSize(width: meterW * 2 + gap, height: 18)

        // The handler runs at draw time, so labelColor matches a light or dark menu bar.
        return NSImage(size: size, flipped: false) { _ in
            for (i, (label, v)) in [("CPU", cpu), ("RAM", ram)].enumerated() {
                let x = CGFloat(i) * (meterW + gap)
                label.draw(at: NSPoint(x: x, y: 4),
                           withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])
                drawBar(in: NSRect(x: x + labelW, y: 6, width: barW, height: 6), value: v, color: levelColor(v))
                let pct = String(format: "%.0f%%", v * 100)
                let attrs: [NSAttributedString.Key: Any] = [.font: pctFont, .foregroundColor: NSColor.labelColor]
                let w = pct.size(withAttributes: attrs).width
                pct.draw(at: NSPoint(x: x + labelW + barW + 4 + pctW - w, y: 2), withAttributes: attrs)
            }
            return true
        }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
