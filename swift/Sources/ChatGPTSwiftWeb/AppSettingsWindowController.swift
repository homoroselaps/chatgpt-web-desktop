import AppKit
import ChatGPTSwiftWebCore

struct AppSettingsState {
    let appVersion: String
    let currentProfileName: String
    let startupProfileName: String
    let homepage: String
    let promptDraftRestoreEnabled: Bool
    let promptDraftSummary: String
    let backgroundCompletionNotificationsEnabled: Bool
    let notificationPermissionStatus: String
    let profileIsolation: String
    let fingerprintName: String
    let enhancedPrivacyEnabled: Bool
    let webRTCProtectionEnabled: Bool
    let rejectNonEssentialCookiesEnabled: Bool
    let keepThirdPartyLinksInApp: Bool
    let windowTitleDisplayMode: WindowTitleDisplayMode
    let notesAutomationStatus: String
    let updateStatus: String
    let distributionStatus: String
    var autoOpenFinderAfterDownload: Bool = false
    var networkStatus: String = "Not checked"
    var quickWindowEnabled: Bool = false
    var quickWindowShortcut: String = "⌘⇧Space"

}

struct AppSettingsCallbacks {
    let setPromptDraftRestore: (Bool) -> Void
    let setBackgroundCompletionNotifications: (Bool) -> Void
    let setWebRTCProtection: (Bool) -> Void
    let setRejectNonEssentialCookies: (Bool) -> Void
    let setThirdPartyLinksInApp: (Bool) -> Void
    let setWindowTitleDisplayMode: (WindowTitleDisplayMode) -> Void
    let setEnhancedPrivacy: (Bool) -> Void
    let openNotesAutomationPrivacy: () -> Void
    let showDiagnostics: () -> Void
    let checkForUpdates: () -> Void
    let openReleasePage: () -> Void
    var setAutoOpenFinderAfterDownload: (Bool) -> Void = { _ in }
    var clearCurrentDraft: () -> Void = {}
    var setQuickWindowEnabled: (Bool) -> Void = { _ in }
    var setQuickWindowShortcut: (QuickWindowShortcut) -> Void = { _ in }
    var showDownloads: @MainActor () -> Void = {}

}

final class AppSettingsWindowController: NSWindowController {
    private enum Section: Int, CaseIterable {
        case general
        case quickWindow
        case privacy
        case notes
        case distribution

        var title: String {
            switch self {
            case .general:
                return "General"
            case .quickWindow:
                return "Quick Window"
            case .privacy:
                return "Privacy"
            case .notes:
                return "Notes"
            case .distribution:
                return "Distribution"
            }
        }
    }

    private var state: AppSettingsState
    private let callbacks: AppSettingsCallbacks
    private var selectedSection = Section.general
    private let sidebarStack = NSStackView()
    private let contentStack = NSStackView()
    let contentScrollView = NSScrollView()
    private var sectionButtons: [NSButton] = []

    init(state: AppSettingsState, callbacks: AppSettingsCallbacks) {
        self.state = state
        self.callbacks = callbacks

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }

        super.init(window: window)
        setupContent()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: AppSettingsState) {
        self.state = state
        render()
    }

    override func showWindow(_ sender: Any?) {
        window?.centerSettingsWindowBeforeFirstShow()
        super.showWindow(sender)
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for section in Section.allCases {
            let button = NSButton(title: section.title, target: self, action: #selector(selectSection(_:)))
            button.tag = section.rawValue
            button.isBordered = false
            button.alignment = .left
            button.setButtonType(.momentaryChange)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.widthAnchor.constraint(equalToConstant: 128).isActive = true
            sidebarStack.addArrangedSubview(button)
            sectionButtons.append(button)
        }

        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentArea)

        contentScrollView.borderType = .noBorder
        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(contentScrollView)

        let contentDocument = FlippedDocumentView()
        contentDocument.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.documentView = contentDocument

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 24, right: 28)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentDocument.addSubview(contentStack)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 156),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),

            contentArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: root.topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            contentDocument.leadingAnchor.constraint(equalTo: contentScrollView.contentView.leadingAnchor),
            contentDocument.trailingAnchor.constraint(equalTo: contentScrollView.contentView.trailingAnchor),
            contentDocument.topAnchor.constraint(equalTo: contentScrollView.contentView.topAnchor),
            contentDocument.widthAnchor.constraint(equalTo: contentScrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: contentDocument.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentDocument.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentDocument.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentDocument.bottomAnchor)
        ])
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = Section(rawValue: sender.tag) else {
            return
        }
        selectedSection = section
        render()
    }

    private func render() {
        for (index, button) in sectionButtons.enumerated() {
            let section = Section(rawValue: index)
            let isSelected = section == selectedSection
            button.title = "\(isSelected ? "●" : " ") \(section?.title ?? "")"
            button.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            button.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        }

        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch selectedSection {
        case .general:
            renderGeneral()
        case .quickWindow:
            renderQuickWindow()
        case .privacy:
            renderPrivacy()
        case .notes:
            renderNotes()
        case .distribution:
            renderDistribution()
        }
    }

    private func renderGeneral() {
        addHeader("General", "This window loads chatgpt.com, with native window controls, status, privacy, and system integration.")
        addKeyValue("Version", state.appVersion)
        addKeyValue("Current Profile", state.currentProfileName)
        addKeyValue("Startup Profile", state.startupProfileName)
        addKeyValue("Profile Homepage", state.homepage)
        addToggle(
            "Save Drafts Locally",
            detail: "Saves recent input in the background and keeps it after replies. Restore or clear drafts from the Edit menu.",
            state: state.promptDraftRestoreEnabled,
            action: #selector(togglePromptDraftRestore(_:))
        )
        addKeyValue("Current Draft", state.promptDraftSummary)
        addActionButton("Clear Profile Drafts", action: #selector(clearCurrentDraft(_:)))
        addToggle(
            "Background Completion Notifications",
            detail: "Sends a macOS notification when ChatGPT finishes a reply while the window is in the background.",
            state: state.backgroundCompletionNotificationsEnabled,
            action: #selector(toggleBackgroundCompletionNotifications(_:))
        )
        addToggle("Open Finder After Downloads", detail: "Off by default. Completed downloads appear in an in-app notification and the Download Center.", state: state.autoOpenFinderAfterDownload, action: #selector(toggleAutoOpenFinder(_:)))
        addKeyValue("Network Status", state.networkStatus)
        addKeyValue("Notification Permission", state.notificationPermissionStatus)
        addKeyValue("Data Isolation", state.profileIsolation)
        addActionButton("Open Diagnostics", action: #selector(showDiagnostics(_:)))
        addActionButton("Open Download Center", action: #selector(showDownloads(_:)))
    }

    private func renderQuickWindow() {
        addHeader("Quick Window", "Off by default. Use a global keyboard shortcut to open a compact window to write messages and read replies.")
        addToggle("Enable Quick Window", detail: "Loads the page when opened and releases the window when closed. Uses the current profile each time.", state: state.quickWindowEnabled, action: #selector(toggleQuickWindow(_:)))
        let recorder = ShortcutRecorderButton(shortcut: QuickWindowPreferences.shortcut) { [weak self] shortcut in
            self?.callbacks.setQuickWindowShortcut(shortcut)
        }
        contentStack.addArrangedSubview(recorder)
        addKeyValue("Shortcut Status", QuickWindowHotKey.shared.statusText)

    }

    private func renderPrivacy() {
        addHeader("Privacy", "Changes are saved immediately and apply to window titles or privacy settings for the current profile.")
        addWindowTitleDisplayOptions()
        addToggle(
            "WebRTC Protection",
            detail: "Blocks WebRTC constructors. Recreates the current WebView to apply the change fully.",
            state: state.webRTCProtectionEnabled,
            action: #selector(toggleWebRTC(_:))
        )
        addToggle(
            "Reject Nonessential ChatGPT Cookies by Default",
            detail: "On by default. Sets ChatGPT consent cookies to reject nonessential cookies in each profile, preserving login, security, and functional cookies. Turning this off removes only the four consent cookies set by this app. You can then choose in the webpage's Cookie Preferences.",
            state: state.rejectNonEssentialCookiesEnabled,
            action: #selector(toggleRejectNonEssentialCookies(_:))
        )
        addToggle(
            "Open Third-Party Links in App",
            detail: "When off, non-OpenAI links open in your default browser.",
            state: state.keepThirdPartyLinksInApp,
            action: #selector(toggleThirdPartyLinks(_:))
        )
        addToggle(
            "Enhanced Privacy (Current Profile)",
            detail: "Enables GPC, tracking parameter removal, and reduced referrer information for this profile.",
            state: state.enhancedPrivacyEnabled,
            action: #selector(toggleEnhancedPrivacy(_:))
        )
        addKeyValue("Fingerprint Preset", state.fingerprintName)
    }

    private func addWindowTitleDisplayOptions() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Window Title")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        stack.addArrangedSubview(titleLabel)

        for (index, mode) in WindowTitleDisplayMode.allCases.enumerated() {
            let button = NSButton(
                radioButtonWithTitle: Self.windowTitleOptionLabel(mode),
                target: self,
                action: #selector(selectWindowTitleDisplayMode(_:))
            )
            button.tag = index
            button.state = state.windowTitleDisplayMode == mode ? .on : .off
            button.font = .systemFont(ofSize: 13, weight: .regular)
            stack.addArrangedSubview(button)
        }

        let detailLabel = wrappingLabel(
            "Account details are hidden by default. Profile Name shortens email addresses to the part before @, which may still contain a name or phone number.",
            color: .secondaryLabelColor
        )
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(detailLabel)
        contentStack.addArrangedSubview(stack)
    }

    private static func windowTitleOptionLabel(_ mode: WindowTitleDisplayMode) -> String {
        switch mode {
        case .appNameOnly:
            return "ChatGPT Swift Only"
        case .profileName:
            return "Profile Name"
        case .fullProfileName:
            return "Full Email Address"
        }
    }

    private func renderNotes() {
        addHeader("Notes", "Inserts the title and body of the first selected Apple Note into the webpage's input box. Long notes are truncated. It does not send the message automatically or read IDEs, Terminal, or code projects.")
        addKeyValue("Automation Permission", state.notesAutomationStatus)
        addActionButton("Open Automation Settings", action: #selector(openNotesAutomationPrivacy(_:)))
    }

    private func renderDistribution() {
        addHeader("Distribution", "Local self-signing supports installation on this Mac and manual GitHub Release checks. Sparkle updates across devices require a stable, trusted Developer ID signature and an EdDSA appcast.")
        addKeyValue("Update Status", state.updateStatus)
        addKeyValue("Signing Policy", state.distributionStatus)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(makeButton("Check for Updates", action: #selector(checkForUpdates(_:))))
        buttonRow.addArrangedSubview(makeButton("Open Release Page", action: #selector(openReleasePage(_:))))
        contentStack.addArrangedSubview(buttonRow)
    }

    private func addHeader(_ title: String, _ detail: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)

        let detailLabel = wrappingLabel(detail, color: .secondaryLabelColor)
        contentStack.addArrangedSubview(detailLabel)

        addSpacer(height: 4)
    }

    private func addKeyValue(_ key: String, _ value: String) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyLabel.textColor = .secondaryLabelColor

        let valueLabel = wrappingLabel(value, color: .labelColor)
        valueLabel.font = .systemFont(ofSize: 13, weight: .regular)

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        contentStack.addArrangedSubview(row)
    }

    private func addToggle(_ title: String, detail: String, state: Bool, action: Selector) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.font = .systemFont(ofSize: 13, weight: .regular)
        button.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = wrappingLabel(detail, color: .secondaryLabelColor)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)

        stack.addArrangedSubview(button)
        stack.addArrangedSubview(detailLabel)
        contentStack.addArrangedSubview(stack)
    }

    private func addActionButton(_ title: String, action: Selector) {
        contentStack.addArrangedSubview(makeButton(title, action: action))
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    private func wrappingLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = color
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func addSpacer(height: CGFloat) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        contentStack.addArrangedSubview(spacer)
    }

    @objc private func toggleAutoOpenFinder(_ sender: NSButton) { callbacks.setAutoOpenFinderAfterDownload(sender.state == .on) }

    @objc private func clearCurrentDraft(_ sender: Any?) { callbacks.clearCurrentDraft() }

    @objc private func toggleQuickWindow(_ sender: NSButton) { callbacks.setQuickWindowEnabled(sender.state == .on) }



    @objc private func showDownloads(_ sender: Any?) { callbacks.showDownloads() }

    @objc private func toggleWebRTC(_ sender: NSButton) {
        callbacks.setWebRTCProtection(sender.state == .on)
    }

    @objc private func toggleRejectNonEssentialCookies(_ sender: NSButton) {
        callbacks.setRejectNonEssentialCookies(sender.state == .on)
    }

    @objc private func togglePromptDraftRestore(_ sender: NSButton) {
        callbacks.setPromptDraftRestore(sender.state == .on)
    }

    @objc private func toggleBackgroundCompletionNotifications(_ sender: NSButton) {
        callbacks.setBackgroundCompletionNotifications(sender.state == .on)
    }

    @objc private func toggleThirdPartyLinks(_ sender: NSButton) {
        callbacks.setThirdPartyLinksInApp(sender.state == .on)
    }

    @objc private func selectWindowTitleDisplayMode(_ sender: NSButton) {
        guard WindowTitleDisplayMode.allCases.indices.contains(sender.tag) else {
            return
        }
        callbacks.setWindowTitleDisplayMode(WindowTitleDisplayMode.allCases[sender.tag])
    }

    @objc private func toggleEnhancedPrivacy(_ sender: NSButton) {
        callbacks.setEnhancedPrivacy(sender.state == .on)
    }

    @objc private func openNotesAutomationPrivacy(_ sender: Any?) {
        callbacks.openNotesAutomationPrivacy()
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        callbacks.showDiagnostics()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        callbacks.checkForUpdates()
    }

    @objc private func openReleasePage(_ sender: Any?) {
        callbacks.openReleasePage()
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSWindow {
    func centerSettingsWindowBeforeFirstShow() {
        guard !isVisible else {
            return
        }
        center()
    }
}
