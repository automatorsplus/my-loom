import AppKit

/// A slider inside a menu, with its name above it, such as Blur Strength under Background. It
/// reports every change while it's dragged, so what it controls can follow live.
final class MenuSliderView: NSView {
    var onChange: ((Double) -> Void)?
    var isEnabled = true {
        didSet {
            slider.isEnabled = isEnabled
            label.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    // Lined up with the titles of the menu's other items.
    private static let leftInset: CGFloat = 21
    private static let rightInset: CGFloat = 14
    private let label: NSTextField
    private let slider: NSSlider

    init(title: String, value: Double, minimumSymbol: String, maximumSymbol: String, width: CGFloat = 250) {
        label = NSTextField(labelWithString: title)
        slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        label.font = .menuFont(ofSize: 0)
        label.frame.origin = NSPoint(x: Self.leftInset, y: 28)
        label.sizeToFit()
        addSubview(label)

        let small = NSImageView(image: NSImage(systemSymbolName: minimumSymbol, accessibilityDescription: nil)!)
        let large = NSImageView(image: NSImage(systemSymbolName: maximumSymbol, accessibilityDescription: nil)!)
        for icon in [small, large] {
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            addSubview(icon)
        }
        small.frame = NSRect(x: Self.leftInset, y: 6, width: 16, height: 16)
        large.frame = NSRect(x: width - Self.rightInset - 16, y: 6, width: 16, height: 16)

        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        slider.frame = NSRect(x: small.frame.maxX + 6, y: 4, width: large.frame.minX - small.frame.maxX - 12, height: 20)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() {
        onChange?(slider.doubleValue)
    }
}
