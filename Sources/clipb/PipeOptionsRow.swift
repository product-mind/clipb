import AppKit

/// One horizontal row of pipe options: rounded buttons labeled with the
/// pipes' `name`s and their Cmd+digit keys. Shared by the popup and the
/// Cmd+Shift+X chooser so the two cannot drift apart.
final class PipeOptionsRow: NSStackView {
    /// Fires with the option index when its button is clicked.
    var onPick: ((Int) -> Void)?

    private(set) var strip = PipeStrip(pipes: [])

    static let keySymbol = "⌘"

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The button title: the pipe name, then its Cmd+digit key.
    static func optionTitle(name: String, digit: Int) -> String {
        "\(name)  \(keySymbol)\(digit)"
    }

    func setPipes(_ pipes: [PipeCommand]) {
        strip = PipeStrip(pipes: pipes)
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, option) in strip.options.enumerated() {
            addArrangedSubview(optionButton(option, index: index))
        }
    }

    private func optionButton(_ option: PipeStrip.Option, index: Int) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(optionClicked(_:)))
        button.bezelStyle = .rounded
        button.tag = index
        button.attributedTitle = attributedTitle(for: option)
        // Clicking it must not pull focus out of the search field.
        button.refusesFirstResponder = true
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        // Too many options for one row: shrink the labels instead of clipping.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// The name reads as the label; the key suffix sits back so it never competes with it.
    private func attributedTitle(for option: PipeStrip.Option) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(
            string: Self.optionTitle(name: option.label, digit: option.digit),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        let suffix = "  \(Self.keySymbol)\(option.digit)"
        let suffixRange = NSRange(location: title.length - suffix.utf16.count, length: suffix.utf16.count)
        title.addAttribute(
            .font,
            // A shortcut looks like a menu key: smaller tabular digits.
            value: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            range: suffixRange
        )
        title.addAttribute(
            .foregroundColor,
            // The name's ink, one step quieter - no new hue on the bezel.
            value: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.labelColor
                    : NSColor.black.withAlphaComponent(0.65)
            }),
            range: suffixRange
        )
        return title
    }

    @objc private func optionClicked(_ sender: NSButton) {
        guard strip.pipes.indices.contains(sender.tag) else { return }
        onPick?(sender.tag)
    }
}
