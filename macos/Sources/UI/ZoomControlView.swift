import AppKit

/// Toolbar zoom control: [−] ──●── [+]  125%
/// Purely presentational — the viewer owns the zoom state and feeds it back
/// here so wheel/pinch/menu zooming moves the slider too.
final class ZoomControlView: NSView {
    /// Called when the user changes zoom through this control.
    var onZoomChange: ((CGFloat) -> Void)?

    private let minimum: CGFloat
    private let maximum: CGFloat
    private let step: CGFloat

    private let slider: NSSlider
    private let percentLabel: NSTextField

    init(minimum: CGFloat, maximum: CGFloat, step: CGFloat) {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        slider = NSSlider(value: 1, minValue: minimum, maxValue: maximum, target: nil, action: nil)
        percentLabel = NSTextField(labelWithString: "100%")
        super.init(frame: .zero)

        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.toolTip = "Zoom (⌘+scroll or pinch works too)"
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        percentLabel.toolTip = "Current zoom — ⌘0 resets to 100%"

        let minusButton = symbolButton("minus", description: "Zoom Out", action: #selector(decrease(_:)))
        let plusButton = symbolButton("plus", description: "Zoom In", action: #selector(increase(_:)))

        let stack = NSStackView(views: [minusButton, slider, plusButton, percentLabel])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// External update (wheel, pinch, menu, mode switch) — no callback fired.
    func setDisplayedZoom(_ scale: CGFloat) {
        slider.doubleValue = Double(scale)
        percentLabel.stringValue = "\(Int((scale * 100).rounded()))%"
    }

    private func symbolButton(_ symbol: String, description: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = description
        return button
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        emit(CGFloat(sender.doubleValue))
    }

    @objc private func decrease(_ sender: Any?) {
        emit(CGFloat(slider.doubleValue) - step)
    }

    @objc private func increase(_ sender: Any?) {
        emit(CGFloat(slider.doubleValue) + step)
    }

    private func emit(_ scale: CGFloat) {
        let clamped = min(max(scale, minimum), maximum)
        setDisplayedZoom(clamped)
        onZoomChange?(clamped)
    }
}
