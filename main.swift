import Cocoa

// MARK: - Memory

struct MemoryInfo {
    var total: UInt64
    var used: UInt64
    var free: UInt64
    var active: UInt64
    var inactive: UInt64
    var wired: UInt64
    var compressed: UInt64

    var usedPercentage: Double {
        Double(used) / Double(total) * 100
    }
}

func getMemoryInfo() -> MemoryInfo {
    let host = mach_host_self()
    var size = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    var stats = vm_statistics64_data_t()

    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &size)
        }
    }

    let total = Foundation.ProcessInfo.processInfo.physicalMemory
    let pageSize = UInt64(vm_kernel_page_size)

    if result == KERN_SUCCESS {
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let used = active + wired + compressed

        return MemoryInfo(
            total: total, used: used, free: free,
            active: active, inactive: inactive,
            wired: wired, compressed: compressed
        )
    }

    return MemoryInfo(
        total: total, used: 0, free: 0,
        active: 0, inactive: 0, wired: 0, compressed: 0
    )
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.1fG", gb) }
    return String(format: "%.0fM", Double(bytes) / 1_048_576)
}

// MARK: - Memory pressure

enum PressureLevel: Int {
    case normal = 1
    case warn = 2
    case critical = 4

    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warn: return .systemYellow
        case .critical: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warn: return "Warning"
        case .critical: return "Critical"
        }
    }
}

func getMemoryPressure() -> PressureLevel {
    var pressure: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
    if result == 0, let level = PressureLevel(rawValue: Int(pressure)) {
        return level
    }
    return .normal
}

// MARK: - Swap

struct SwapInfo {
    var total: UInt64
    var used: UInt64
}

func getSwapInfo() -> SwapInfo {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
        return SwapInfo(total: usage.xsu_total, used: usage.xsu_used)
    }
    return SwapInfo(total: 0, used: 0)
}

// MARK: - CPU

struct CPUTicks {
    var user: UInt64; var system: UInt64; var idle: UInt64; var nice: UInt64
    var total: UInt64 { user + system + idle + nice }
    var active: UInt64 { user + system + nice }
}

var previousTicks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
var cpuBootstrapped = false

func getCPUTicks() -> CPUTicks {
    var size = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    var info = host_cpu_load_info_data_t()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    if r == KERN_SUCCESS {
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }
    return CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
}

func getCPUUsage() -> Double {
    let cur = getCPUTicks()
    defer { previousTicks = cur }
    if !cpuBootstrapped { cpuBootstrapped = true; return 0 }
    let dT = cur.total - previousTicks.total
    guard dT > 0 else { return 0 }
    return Double(cur.active - previousTicks.active) / Double(dT) * 100
}

// MARK: - Top processes

struct TopProcess { var name: String; var memoryKB: UInt64 }

func getTopProcesses(count: Int = 5) -> [TopProcess] {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-Ao", "rss=,comm=", "-m"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var results: [TopProcess] = []
    for line in output.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        let parts = t.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let rss = UInt64(parts[0]) else { continue }
        let name = (String(parts[1]) as NSString).lastPathComponent
        results.append(TopProcess(name: name, memoryKB: rss))
        if results.count >= count { break }
    }
    return results
}

// MARK: - History

let kMaxHistory = 30
var memHistory: [Double] = []
var cpuHistory: [Double] = []

func pushValue(_ value: Double, to history: inout [Double]) {
    history.append(value)
    if history.count > kMaxHistory { history.removeFirst(history.count - kMaxHistory) }
}

// MARK: - Drawing

func cpuColor(_ pct: Double) -> NSColor {
    if pct < 50 { return .systemCyan }
    if pct < 80 { return .systemOrange }
    return .systemRed
}

func drawSparkline(in rect: NSRect, history: [Double], color: NSColor, maxSamples: Int) {
    let count = history.count
    NSColor.gray.withAlphaComponent(0.2).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    guard count >= 1 else { return }

    let step = rect.width / CGFloat(maxSamples - 1)
    let xOff = step * CGFloat(maxSamples - count)

    if count == 1 {
        let y = rect.minY + rect.height * CGFloat(history[0] / 100)
        color.setStroke()
        let p = NSBezierPath(); p.move(to: NSPoint(x: rect.minX, y: y))
        p.line(to: NSPoint(x: rect.maxX, y: y)); p.lineWidth = 1.5; p.stroke()
        return
    }

    let line = NSBezierPath()
    for (i, val) in history.enumerated() {
        let x = xOff + rect.minX + step * CGFloat(i)
        let y = rect.minY + rect.height * CGFloat(min(val, 100) / 100)
        if i == 0 { line.move(to: NSPoint(x: x, y: y)) }
        else { line.line(to: NSPoint(x: x, y: y)) }
    }

    let fill = line.copy() as! NSBezierPath
    fill.line(to: NSPoint(x: xOff + rect.minX + step * CGFloat(count - 1), y: rect.minY))
    fill.line(to: NSPoint(x: xOff + rect.minX, y: rect.minY))
    fill.close()

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).addClip()
    color.withAlphaComponent(0.25).setFill(); fill.fill()
    color.setStroke(); line.lineWidth = 1.5
    line.lineCapStyle = .round; line.lineJoinStyle = .round; line.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func makeDualGraphImage(
    memHistory: [Double], cpuHistory: [Double],
    memColor: NSColor, cpuPct: Double,
    width: CGFloat = 64, height: CGFloat = 18
) -> NSImage {
    let pad: CGFloat = 2; let gap: CGFloat = 3
    let gw = (width - pad * 2 - gap) / 2; let gh = height - pad * 2
    let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        drawSparkline(in: NSRect(x: pad, y: pad, width: gw, height: gh),
                      history: memHistory, color: memColor, maxSamples: kMaxHistory)
        drawSparkline(in: NSRect(x: pad + gw + gap, y: pad, width: gw, height: gh),
                      history: cpuHistory, color: cpuColor(cpuPct), maxSamples: kMaxHistory)
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - Display mode

enum DisplayMode: String, CaseIterable {
    case graph, text
    var menuLabel: String {
        switch self { case .graph: return "Graph"; case .text: return "Text" }
    }
}

let kDisplayModeKey = "displayMode"

// MARK: - Launch at Login

func launchAgentDir() -> String { NSHomeDirectory() + "/Library/LaunchAgents" }
func launchAgentPath() -> String { launchAgentDir() + "/com.memorybar.app.plist" }

func appBundlePath() -> String {
    let exec = Foundation.ProcessInfo.processInfo.arguments[0]
    let url = URL(fileURLWithPath: exec)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let appPath = url.appendingPathComponent("MemoryBar.app").path
    if FileManager.default.fileExists(atPath: appPath + "/Contents/MacOS/MemoryBar") {
        return appPath
    }
    return exec
}

func isLaunchAtLoginEnabled() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentPath())
}

func setLaunchAtLogin(_ enabled: Bool) {
    if enabled {
        let plist: [String: Any] = [
            "Label": "com.memorybar.app",
            "ProgramArguments": ["/usr/bin/open", "-a", appBundlePath()],
            "RunAtLoad": true,
        ]
        try? FileManager.default.createDirectory(atPath: launchAgentDir(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: launchAgentPath(), atomically: true)
    } else {
        try? FileManager.default.removeItem(atPath: launchAgentPath())
    }
}

// MARK: - Section state

let kCollapsedKey = "collapsedSections"
var collapsedSections: Set<String> = {
    Set(UserDefaults.standard.stringArray(forKey: kCollapsedKey) ?? [])
}()

func isSectionCollapsed(_ key: String) -> Bool { collapsedSections.contains(key) }

func toggleSectionState(_ key: String) {
    if collapsedSections.contains(key) { collapsedSections.remove(key) }
    else { collapsedSections.insert(key) }
    UserDefaults.standard.set(Array(collapsedSections), forKey: kCollapsedKey)
}

// MARK: - HoverView

class HoverView: NSView {
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
        layer?.backgroundColor = bounds.contains(loc)
            ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
    }
}

// MARK: - PopoverViewController

class PopoverViewController: NSViewController {
    let W: CGFloat = 280
    let pad: CGFloat = 12
    var innerW: CGFloat { W - pad * 2 }
    let rowH: CGFloat = 22

    var mainStack: NSStackView!

    // Collapsible sections
    var memDetails: NSStackView!; var memChevron: NSImageView!; var memSummary: NSTextField!
    var procDetails: NSStackView!; var procChevron: NSImageView!
    var dispDetails: NSStackView!; var dispChevron: NSImageView!; var dispSummary: NSTextField!

    // Updatable labels
    var pressureLabel: NSTextField!
    var memValues: [NSTextField] = []
    var swapRow: NSView!; var swapLabel: NSTextField!
    var cpuLabel: NSTextField!
    var procNames: [NSTextField] = []; var procVals: [NSTextField] = []
    var dispChecks: [NSTextField] = []
    var loginCheck: NSTextField!

    var displayMode: DisplayMode = .graph
    var onDisplayModeChanged: ((DisplayMode) -> Void)?
    var onQuit: (() -> Void)?
    var onToggleLogin: (() -> Void)?

    // MARK: - View lifecycle

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        self.view = v

        mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 1
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: v.topAnchor, constant: pad),
            mainStack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: pad),
            mainStack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -pad),
            mainStack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -pad),
            mainStack.widthAnchor.constraint(equalToConstant: innerW),
        ])

        buildMemory()
        addSep()
        buildSwapCPU()
        addSep()
        buildProcesses()
        addSep()
        buildDisplay()
        addSep()
        buildLoginAndQuit()

        applyCollapsedState()
        updateSize(animated: false)
    }

    // MARK: - Build sections

    func buildMemory() {
        let (header, summary, chevron) = makeHeader("Memory", summary: "")
        memSummary = summary; memChevron = chevron
        header.onClick = { [weak self] in
            guard let self = self else { return }
            self.toggle("memory", self.memDetails, self.memChevron, self.memSummary)
        }
        mainStack.addArrangedSubview(header)

        memDetails = NSStackView()
        memDetails.orientation = .vertical; memDetails.alignment = .leading; memDetails.spacing = 0
        memDetails.translatesAutoresizingMaskIntoConstraints = false

        pressureLabel = label("Pressure: —")
        pressureLabel.textColor = .systemGreen
        memDetails.addArrangedSubview(indentWrap(pressureLabel))

        for key in ["Used", "Active", "Wired", "Compressed", "Inactive", "Free", "Total"] {
            let (row, valL) = kvRow(key, "—")
            memDetails.addArrangedSubview(row)
            memValues.append(valL)
        }
        mainStack.addArrangedSubview(memDetails)
    }

    func buildSwapCPU() {
        swapLabel = label("Swap: —")
        swapRow = fullRow(swapLabel)
        mainStack.addArrangedSubview(swapRow)

        cpuLabel = label("CPU: —")
        mainStack.addArrangedSubview(fullRow(cpuLabel))
    }

    func buildProcesses() {
        let (header, _, chevron) = makeHeader("Top Processes", summary: nil)
        procChevron = chevron
        header.onClick = { [weak self] in
            guard let self = self else { return }
            self.toggle("processes", self.procDetails, self.procChevron, nil)
        }
        mainStack.addArrangedSubview(header)

        procDetails = NSStackView()
        procDetails.orientation = .vertical; procDetails.alignment = .leading; procDetails.spacing = 0
        procDetails.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<5 {
            let (row, valL) = kvRow("—", "—")
            procDetails.addArrangedSubview(row)
            procNames.append(row.subviews.compactMap { $0 as? NSTextField }.first!)
            procVals.append(valL)
        }
        mainStack.addArrangedSubview(procDetails)
    }

    func buildDisplay() {
        let (header, summary, chevron) = makeHeader("Display", summary: "")
        dispSummary = summary; dispChevron = chevron
        header.onClick = { [weak self] in
            guard let self = self else { return }
            self.toggle("display", self.dispDetails, self.dispChevron, self.dispSummary)
        }
        mainStack.addArrangedSubview(header)

        dispDetails = NSStackView()
        dispDetails.orientation = .vertical; dispDetails.alignment = .leading; dispDetails.spacing = 0
        dispDetails.translatesAutoresizingMaskIntoConstraints = false

        for mode in DisplayMode.allCases {
            let row = HoverView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let ck = label(mode == displayMode ? "✓" : "")
            ck.textColor = .controlAccentColor
            ck.font = .systemFont(ofSize: 12, weight: .medium)
            ck.alignment = .center
            ck.translatesAutoresizingMaskIntoConstraints = false
            let lb = label(mode.menuLabel)
            lb.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(ck); row.addSubview(lb)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: innerW),
                row.heightAnchor.constraint(equalToConstant: rowH),
                ck.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                ck.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                ck.widthAnchor.constraint(equalToConstant: 18),
                lb.leadingAnchor.constraint(equalTo: ck.trailingAnchor, constant: 2),
                lb.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            let m = mode
            row.onClick = { [weak self] in
                guard let self = self else { return }
                self.displayMode = m
                self.onDisplayModeChanged?(m)
                self.refreshDispChecks()
            }
            dispDetails.addArrangedSubview(row)
            dispChecks.append(ck)
        }
        mainStack.addArrangedSubview(dispDetails)
    }

    func buildLoginAndQuit() {
        // Launch at Login
        let loginRow = HoverView()
        loginRow.translatesAutoresizingMaskIntoConstraints = false
        loginCheck = label("")
        loginCheck.textColor = .controlAccentColor
        loginCheck.font = .systemFont(ofSize: 12, weight: .medium)
        loginCheck.alignment = .center
        loginCheck.translatesAutoresizingMaskIntoConstraints = false
        let ll = label("Launch at Login"); ll.translatesAutoresizingMaskIntoConstraints = false
        loginRow.addSubview(loginCheck); loginRow.addSubview(ll)
        NSLayoutConstraint.activate([
            loginRow.widthAnchor.constraint(equalToConstant: innerW),
            loginRow.heightAnchor.constraint(equalToConstant: rowH),
            loginCheck.leadingAnchor.constraint(equalTo: loginRow.leadingAnchor, constant: 4),
            loginCheck.centerYAnchor.constraint(equalTo: loginRow.centerYAnchor),
            loginCheck.widthAnchor.constraint(equalToConstant: 18),
            ll.leadingAnchor.constraint(equalTo: loginCheck.trailingAnchor, constant: 2),
            ll.centerYAnchor.constraint(equalTo: loginRow.centerYAnchor),
        ])
        loginRow.onClick = { [weak self] in self?.onToggleLogin?() }
        mainStack.addArrangedSubview(loginRow)

        addSep()

        // Quit
        let qr = HoverView()
        qr.translatesAutoresizingMaskIntoConstraints = false
        let ql = label("Quit MemoryBar"); ql.translatesAutoresizingMaskIntoConstraints = false
        let qs = label("⌘Q"); qs.textColor = .tertiaryLabelColor; qs.font = .systemFont(ofSize: 11)
        qs.translatesAutoresizingMaskIntoConstraints = false
        qr.addSubview(ql); qr.addSubview(qs)
        NSLayoutConstraint.activate([
            qr.widthAnchor.constraint(equalToConstant: innerW),
            qr.heightAnchor.constraint(equalToConstant: rowH),
            ql.leadingAnchor.constraint(equalTo: qr.leadingAnchor, constant: 4),
            ql.centerYAnchor.constraint(equalTo: qr.centerYAnchor),
            qs.trailingAnchor.constraint(equalTo: qr.trailingAnchor, constant: -4),
            qs.centerYAnchor.constraint(equalTo: qr.centerYAnchor),
        ])
        qr.onClick = { [weak self] in self?.onQuit?() }
        mainStack.addArrangedSubview(qr)
    }

    // MARK: - Collapsible toggle

    func toggle(_ key: String, _ details: NSStackView, _ chevron: NSImageView, _ summary: NSTextField?) {
        toggleSectionState(key)
        let collapsed = isSectionCollapsed(key)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            details.isHidden = collapsed
            chevron.animator().frameCenterRotation = collapsed ? 0 : -90

            self.view.layoutSubtreeIfNeeded()
        } completionHandler: {
            self.updateSize(animated: true)
        }

        // Show summary when collapsed
        if let summary = summary { summary.isHidden = !collapsed }
    }

    func applyCollapsedState() {
        memDetails.isHidden = isSectionCollapsed("memory")
        memChevron.frameCenterRotation = isSectionCollapsed("memory") ? 0 : -90
        memSummary.isHidden = !isSectionCollapsed("memory")

        procDetails.isHidden = isSectionCollapsed("processes")
        procChevron.frameCenterRotation = isSectionCollapsed("processes") ? 0 : -90

        dispDetails.isHidden = isSectionCollapsed("display")
        dispChevron.frameCenterRotation = isSectionCollapsed("display") ? 0 : -90
        dispSummary.isHidden = !isSectionCollapsed("display")
    }

    func updateSize(animated: Bool) {
        view.layoutSubtreeIfNeeded()
        let h = mainStack.fittingSize.height + pad * 2
        let size = NSSize(width: W, height: h)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.preferredContentSize = size
            }
        } else {
            preferredContentSize = size
        }
    }

    // MARK: - Data update

    func update(mem: MemoryInfo, pressure: PressureLevel, cpuPct: Double, swap: SwapInfo) {
        guard isViewLoaded else { return }
        let pct = mem.usedPercentage
        let pctStr = String(format: "%.0f%%", pct)

        // Memory header summary
        memSummary.stringValue = "\(formatBytes(mem.used))/\(formatBytes(mem.total))"

        // Pressure
        pressureLabel.stringValue = "Pressure: \(pressure.label)"
        pressureLabel.textColor = pressure.color

        // Memory values
        let vals = [
            "\(formatBytes(mem.used)) (\(pctStr))",
            formatBytes(mem.active), formatBytes(mem.wired), formatBytes(mem.compressed),
            formatBytes(mem.inactive), formatBytes(mem.free), formatBytes(mem.total),
        ]
        for (i, v) in vals.enumerated() where i < memValues.count {
            memValues[i].stringValue = v
        }

        // Swap
        if swap.total > 0 {
            swapLabel.stringValue = "Swap: \(formatBytes(swap.used)) / \(formatBytes(swap.total))"
            swapRow.isHidden = false
        } else {
            swapRow.isHidden = true
        }

        // CPU
        cpuLabel.stringValue = String(format: "CPU: %.1f%%", cpuPct)

        // Processes
        let procs = getTopProcesses()
        for i in 0..<5 {
            if i < procs.count {
                procNames[i].stringValue = procs[i].name
                let mb = Double(procs[i].memoryKB) / 1024
                procVals[i].stringValue = mb >= 1024
                    ? String(format: "%.1fG", mb / 1024)
                    : String(format: "%.0fM", mb)
            } else {
                procNames[i].stringValue = ""; procVals[i].stringValue = ""
            }
        }

        // Display summary
        dispSummary.stringValue = displayMode.menuLabel

        // Login checkmark
        loginCheck.stringValue = isLaunchAtLoginEnabled() ? "✓" : ""
    }

    func refreshDispChecks() {
        for (i, mode) in DisplayMode.allCases.enumerated() {
            dispChecks[i].stringValue = mode == displayMode ? "✓" : ""
        }
        dispSummary.stringValue = displayMode.menuLabel
    }

    // MARK: - Helpers

    func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func makeHeader(_ title: String, summary: String?) -> (HoverView, NSTextField, NSImageView) {
        let row = HoverView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let tl = NSTextField(labelWithString: title)
        tl.font = .boldSystemFont(ofSize: 13)
        tl.translatesAutoresizingMaskIntoConstraints = false

        let sl = NSTextField(labelWithString: summary ?? "")
        sl.font = .systemFont(ofSize: 11)
        sl.textColor = .secondaryLabelColor
        sl.alignment = .right
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.isHidden = true  // shown only when collapsed

        let chevron = NSImageView()
        if let img = NSImage(systemSymbolName: "chevron.right",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            chevron.image = img
        }
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.wantsLayer = true

        row.addSubview(tl); row.addSubview(sl); row.addSubview(chevron)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: innerW),
            row.heightAnchor.constraint(equalToConstant: 26),
            tl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            tl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            sl.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            sl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sl.leadingAnchor.constraint(greaterThanOrEqualTo: tl.trailingAnchor, constant: 8),
        ])

        return (row, sl, chevron)
    }

    func kvRow(_ key: String, _ value: String) -> (NSView, NSTextField) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let kl = label(key); kl.textColor = .secondaryLabelColor
        kl.translatesAutoresizingMaskIntoConstraints = false
        let vl = label(value); vl.alignment = .right
        vl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(kl); row.addSubview(vl)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: innerW),
            row.heightAnchor.constraint(equalToConstant: 20),
            kl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            kl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            vl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            vl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            vl.leadingAnchor.constraint(greaterThanOrEqualTo: kl.trailingAnchor, constant: 8),
        ])
        return (row, vl)
    }

    func indentWrap(_ tf: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(tf)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: innerW),
            row.heightAnchor.constraint(equalToConstant: 20),
            tf.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            tf.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func fullRow(_ tf: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(tf)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: innerW),
            row.heightAnchor.constraint(equalToConstant: rowH),
            tf.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            tf.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func addSep() {
        let s = NSView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.wantsLayer = true
        s.layer?.backgroundColor = NSColor.separatorColor.cgColor
        mainStack.addArrangedSubview(s)
        NSLayoutConstraint.activate([
            s.widthAnchor.constraint(equalToConstant: innerW),
            s.heightAnchor.constraint(equalToConstant: 1),
        ])
        mainStack.setCustomSpacing(6, after: mainStack.arrangedSubviews[mainStack.arrangedSubviews.count - 2])
        mainStack.setCustomSpacing(6, after: s)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var popoverVC: PopoverViewController!
    var timer: Timer?
    var displayMode: DisplayMode = .graph
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = UserDefaults.standard.string(forKey: kDisplayModeKey),
           let mode = DisplayMode(rawValue: saved) {
            displayMode = mode
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }

        popoverVC = PopoverViewController()
        popoverVC.displayMode = displayMode
        popoverVC.onDisplayModeChanged = { [weak self] mode in
            self?.displayMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: kDisplayModeKey)
            self?.refreshStatusBar()
        }
        popoverVC.onQuit = { NSApp.terminate(nil) }
        popoverVC.onToggleLogin = {
            setLaunchAtLogin(!isLaunchAtLoginEnabled())
        }

        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        _ = getCPUUsage()
        tick()

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        let mem = getMemoryInfo()
        let pressure = getMemoryPressure()
        let cpuPct = getCPUUsage()
        let swap = getSwapInfo()

        pushValue(mem.usedPercentage, to: &memHistory)
        pushValue(cpuPct, to: &cpuHistory)

        refreshStatusBar()

        if popover.isShown {
            popoverVC.update(mem: mem, pressure: pressure, cpuPct: cpuPct, swap: swap)
        }
    }

    func refreshStatusBar() {
        guard let button = statusItem.button else { return }
        let mem = getMemoryInfo()
        let pressure = getMemoryPressure()
        let cpuPct = cpuHistory.last ?? 0

        switch displayMode {
        case .graph:
            button.title = ""
            button.image = makeDualGraphImage(
                memHistory: memHistory, cpuHistory: cpuHistory,
                memColor: pressure.color, cpuPct: cpuPct)
            button.imagePosition = .imageOnly
            statusItem.length = 68
        case .text:
            button.image = nil
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let memPct = String(format: "%.0f%%", mem.usedPercentage)
            button.title = "M:\(memPct) C:\(String(format: "%.0f%%", cpuPct))"
            button.imagePosition = .noImage
            statusItem.length = NSStatusItem.variableLength
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.close()
        } else if let button = statusItem.button {
            // Show first (forces view loading), then populate data
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            let mem = getMemoryInfo()
            let pressure = getMemoryPressure()
            let cpuPct = cpuHistory.last ?? 0
            let swap = getSwapInfo()
            popoverVC.update(mem: mem, pressure: pressure, cpuPct: cpuPct, swap: swap)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
