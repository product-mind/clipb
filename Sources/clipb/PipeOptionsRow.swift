import AppKit

/// One horizontal row of pipe options: rounded buttons labeled with the
/// pipes' `name`s, optionally with their digit keys printed below. Shared by
/// the popup and the Cmd+Shift+X chooser so the two cannot drift apart.
final class PipeOptionsRow: NSStackView {
    /// Fires with the option index when its button is clicked.
    var onPick: ((Int) -> Void)?

    private(set) var strip = PipeStrip(pipes: [])

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .top
        spacing = 8
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `digitLabel` prefixes each digit; the chooser passes "" (bare keys),
    /// the popup passes nil (its hint line carries the keys instead).
    func setPipes(_ pipes: [PipeCommand], digitLabel: String? = "") {
        strip = PipeStrip(pipes: pipes)
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, option) in strip.options.enumerated() {
            addArrangedSubview(optionView(option, index: index, digitLabel: digitLabel))
        }
    }

    private func optionView(_ option: PipeStrip.Option, index: Int, digitLabel: String?) -> NSView {
        let button = NSButton(title: option.label, target: self, action: #selector(optionClicked(_:)))
        button.bezelStyle = .rounded
        button.tag = index
        // Clicking it must not pull focus out of the search field.
        button.refusesFirstResponder = true
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        // Too many options for one row: shrink the labels instead of clipping.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        guard let digitLabel else { return button }
        // The digit is a click target too: people click the number they see.
        let digit = NSButton(title: "\(digitLabel)\(option.digit)", target: self, action: #selector(optionClicked(_:)))
        digit.isBordered = false
        digit.tag = index
        digit.refusesFirstResponder = true
        digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        digit.contentTintColor = .secondaryLabelColor

        let column = NSStackView(views: [button, digit])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 2
        return column
    }

    @objc private func optionClicked(_ sender: NSButton) {
        guard strip.pipes.indices.contains(sender.tag) else { return }
        onPick?(sender.tag)
    }
}
