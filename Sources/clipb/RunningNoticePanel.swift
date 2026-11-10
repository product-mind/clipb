import AppKit

/// Cannot take key even by accident: the target app's typing must keep flowing.
private final class RunningPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Says a chord's pipe is running, where a failure notice would appear. A chord
/// opens no panel, so a seconds-long job would otherwise look like nothing
/// happened. Unlike `NoticePanel` it is never key and takes no clicks: it only
/// reports, and the run's own exit closes it (SPEC §2.10).
final class RunningNoticePanel {
    private let panel: RunningPanel
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        panel = RunningPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The clicks belong to the app being typed in; this panel is read-only.
        panel.ignoresMouseEvents = true

        let content = NSVisualEffectView(frame: .zero)
        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        panel.contentView = content

        // The same 13 pt the notices use, so a run and its failure look related.
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        // A long pipe name must not stretch the panel off-screen: 420 pt total,
        // less the 14 pt insets, caps the label the way `NoticePanel` does.
        titleLabel.preferredMaxLayoutWidth = 392
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// No `makeKey` and no `NSApp.activate` anywhere here: the frontmost app
    /// keeps the keyboard for the whole run.
    func show(title: String, near anchor: PanelAnchor) {
        titleLabel.stringValue = title
        let size = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}
