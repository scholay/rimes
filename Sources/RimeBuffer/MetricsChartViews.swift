import AppKit

/// A categorical sample. Missing measurements remain nil: charts must not
/// turn a disabled collector or a zero-duration session into a zero speed.
struct MetricsChartSample: Equatable {
    let id: String
    let label: String
    let value: Double?
    let detail: String
    let position: Double?

    init(id: String, label: String, value: Double?, detail: String = "", position: Double? = nil) {
        self.id = id
        self.label = label
        self.value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.detail = detail
        self.position = position.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Small native chart shared by everyday statistics and controlled tests.
/// Values are neither smoothed nor interpolated across missing samples.
final class MetricsLineChartView: NSView {
    var samples: [MetricsChartSample] = [] {
        didSet {
            if let hoveredIndex, !samples.indices.contains(hoveredIndex) { self.hoveredIndex = nil }
            updateAccessibleSummary(); needsDisplay = true
        }
    }
    var unit = "" { didSet { updateAccessibleSummary(); needsDisplay = true } }
    var xAxisLabel = "" { didSet { needsDisplay = true } }
    var emptyMessage = "输入后，这里会出现真实趋势" { didSet { updateAccessibleSummary(); needsDisplay = true } }
    var selectedSampleID: String? { didSet { needsDisplay = true } }
    var accentColor: NSColor? { didSet { needsDisplay = true } }
    var onSelectSample: ((String) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self); updateAccessibleSummary() }
    }

    private var tracking: NSTrackingArea?
    private var hoveredIndex: Int? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { onSelectSample != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibleSummary()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let value = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(value)
        tracking = value
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onSelectSample != nil { addCursorRect(plotRect, cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = sampleIndex(at: point)
        toolTip = hoveredIndex.map { description(for: samples[$0]) }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = sampleIndex(at: convert(event.locationInWindow, from: nil)),
              let onSelectSample else { return }
        window?.makeFirstResponder(self)
        selectedSampleID = samples[index].id
        onSelectSample(samples[index].id)
    }

    override func keyDown(with event: NSEvent) {
        guard let onSelectSample, !samples.isEmpty else { super.keyDown(with: event); return }
        let index = samples.firstIndex { $0.id == selectedSampleID } ?? samples.count - 1
        let next: Int
        switch event.keyCode {
        case 123: next = max(0, index - 1)
        case 124: next = min(samples.count - 1, index + 1)
        case 36, 49: next = index
        default: super.keyDown(with: event); return
        }
        let selectedSample = samples[next]
        selectedSampleID = selectedSample.id
        onSelectSample(selectedSample.id)
        // Selection callbacks may replace the series; retain this value-only
        // snapshot instead of indexing a potentially shorter replacement.
        setAccessibilityValue(description(for: selectedSample))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var plotRect: NSRect {
        NSRect(x: 55, y: 30, width: max(1, bounds.width - 76), height: max(1, bounds.height - 64))
    }

    private func sampleIndex(at point: NSPoint) -> Int? {
        guard !samples.isEmpty, plotRect.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return samples.indices.min { abs(x(at: $0) - point.x) < abs(x(at: $1) - point.x) }
    }

    private func x(at index: Int) -> CGFloat {
        let positions = samples.compactMap(\.position)
        if positions.count == samples.count,
           let first = positions.min(), let last = positions.max(), last > first {
            return plotRect.minX + plotRect.width * CGFloat((positions[index] - first) / (last - first))
        }
        guard samples.count > 1 else { return plotRect.midX }
        return plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(samples.count - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        RimeUI.surface2.setFill(); background.fill()
        RimeUI.border.setStroke(); background.lineWidth = 1; background.stroke()
        let plot = plotRect
        drawText(unit, in: NSRect(x: 16, y: 10, width: bounds.width - 32, height: 15), color: RimeUI.textSecondary)
        let validValues = samples.compactMap(\.value)
        let ceiling = Self.axisMaximum(validValues.max() ?? 0)
        for tick in 0...2 {
            let value = ceiling * Double(tick) / 2
            let y = plot.maxY - plot.height * CGFloat(tick) / 2
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y)); grid.line(to: NSPoint(x: plot.maxX, y: y))
            RimeUI.border.setStroke(); grid.lineWidth = 0.5; grid.stroke()
            drawText(Self.number(value), in: NSRect(x: 5, y: y - 7, width: 42, height: 15),
                     color: RimeUI.textMuted, alignment: .right)
        }
        let middleIndex = samples.indices.min { abs(x(at: $0) - plot.midX) < abs(x(at: $1) - plot.midX) }
        let axisIndices = samples.count > 2 ? [0, middleIndex ?? 0, samples.count - 1] : Array(samples.indices)
        var previousLabelX: CGFloat?
        for index in Set(axisIndices).sorted() {
            // Irregular time samples can cluster near one edge. Keep the two
            // endpoints and suppress a middle label that would overlap them.
            if index != 0, index != samples.count - 1,
               (x(at: index) - x(at: 0) < 76 || x(at: samples.count - 1) - x(at: index) < 76) { continue }
            if let previousLabelX, x(at: index) - previousLabelX < 76 { continue }
            drawText(samples[index].label,
                     in: NSRect(x: min(bounds.width - 80, max(4, x(at: index) - 35)), y: plot.maxY + 9, width: 70, height: 16),
                     color: RimeUI.textMuted, alignment: .center)
            previousLabelX = x(at: index)
        }
        if !xAxisLabel.isEmpty {
            drawText(xAxisLabel, in: NSRect(x: plot.minX, y: 10, width: plot.width, height: 15),
                     color: RimeUI.textMuted, alignment: .right)
        }
        guard !validValues.isEmpty else {
            let icon = RimeUI.symbol("chart.xyaxis.line", pointSize: 25)
            icon?.draw(in: NSRect(x: plot.midX - 14, y: plot.midY - 30, width: 28, height: 28),
                       from: .zero, operation: .sourceOver, fraction: 0.35,
                       respectFlipped: true, hints: nil)
            drawText(emptyMessage, in: NSRect(x: plot.minX, y: plot.midY + 7, width: plot.width, height: 18),
                     color: RimeUI.textSecondary, alignment: .center)
            return
        }
        let accent = accentColor ?? RimeUI.accentGreen
        let line = NSBezierPath()
        var continues = false
        for (index, sample) in samples.enumerated() {
            guard let value = sample.value else { continues = false; continue }
            let point = NSPoint(x: x(at: index), y: plot.maxY - plot.height * CGFloat(value / ceiling))
            if continues { line.line(to: point) } else { line.move(to: point) }
            continues = true
        }
        accent.setStroke(); line.lineWidth = 2; line.lineJoinStyle = .round; line.stroke()
        for (index, sample) in samples.enumerated() {
            guard let value = sample.value else { continue }
            let point = NSPoint(x: x(at: index), y: plot.maxY - plot.height * CGFloat(value / ceiling))
            let selected = sample.id == selectedSampleID || index == hoveredIndex
            let radius: CGFloat = selected ? 4.5 : 2.5
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            if selected {
                let marker = NSBezierPath()
                marker.move(to: NSPoint(x: point.x, y: plot.minY)); marker.line(to: NSPoint(x: point.x, y: plot.maxY))
                accent.withAlphaComponent(0.22).setStroke(); marker.lineWidth = 1; marker.stroke()
            }
        }
        if let hoveredIndex, samples.indices.contains(hoveredIndex) {
            let sample = samples[hoveredIndex]
            let caption = "\(sample.label)  \(sample.value.map(Self.number) ?? "—") \(unit)"
            drawText(caption, in: NSRect(x: plot.minX, y: 10, width: plot.width, height: 15),
                     color: RimeUI.textPrimary, alignment: .center)
        }
    }

    static func axisMaximum(_ maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        let scale = pow(10, floor(log10(maximum)))
        let relative = maximum / scale
        let factor: Double = relative <= 1 ? 1 : relative <= 2 ? 2 : relative <= 5 ? 5 : 10
        return factor * scale
    }

    private static func number(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.1f万", value / 10_000) }
        if value >= 100 { return String(format: "%.0f", value) }
        return value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func description(for sample: MetricsChartSample) -> String {
        "\(sample.label)：\(sample.value.map(Self.number) ?? "无记录") \(unit)\(sample.detail.isEmpty ? "" : "；" + sample.detail)"
    }

    private func updateAccessibleSummary() {
        setAccessibilityLabel("\(unit)趋势图")
        setAccessibilityValue(samples.contains { $0.value != nil }
                              ? samples.map { description(for: $0) }.joined(separator: "，")
                              : emptyMessage)
        setAccessibilityHelp(onSelectSample == nil ? nil : "可用左右方向键选择数据点。")
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }
}

/// One prominent measurement, with secondary explanation available on demand.
final class MetricsValueCard: NSView {
    private let title: String
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let unitLabel = NSTextField(labelWithString: "")

    init(title: String, symbolName: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = RimeUI.symbol(symbolName, pointSize: 13, weight: .medium)
        icon.contentTintColor = RimeUI.accentTextColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        caption.stringValue = title
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = RimeUI.textSecondary
        let heading = NSStackView(views: [icon, caption])
        heading.orientation = .horizontal; heading.spacing = 7; heading.alignment = .centerY
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 27, weight: .semibold)
        valueLabel.textColor = RimeUI.textPrimary
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unitLabel.font = .systemFont(ofSize: 10)
        unitLabel.textColor = RimeUI.textMuted
        let reading = NSStackView(views: [valueLabel, unitLabel])
        reading.orientation = .horizontal; reading.spacing = 4; reading.alignment = .firstBaseline
        let stack = NSStackView(views: [heading, reading])
        stack.orientation = .vertical; stack.spacing = 11; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        update(value: "—")
    }

    required init?(coder: NSCoder) { nil }

    func update(value: String, unit: String = "", detail: String = "") {
        valueLabel.stringValue = value
        unitLabel.stringValue = unit
        toolTip = detail.isEmpty ? "\(title)：\(value) \(unit)" : detail
        setAccessibilityLabel(title)
        setAccessibilityValue("\(value) \(unit)")
        setAccessibilityHelp(detail)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        caption.textColor = RimeUI.textSecondary; valueLabel.textColor = RimeUI.textPrimary
        unitLabel.textColor = RimeUI.textMuted; icon.contentTintColor = RimeUI.accentTextColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        RimeUI.surface2.setFill(); path.fill()
        RimeUI.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
