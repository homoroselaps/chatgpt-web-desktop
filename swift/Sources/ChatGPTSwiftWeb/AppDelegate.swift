import AppKit
import ChatGPTSwiftWebCore
import Darwin
import Foundation
import OSLog
import Sparkle
import UniformTypeIdentifiers
import UserNotifications
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var mainController: BrowserWindowController?
    var quickController: BrowserWindowController?
    private var incognitoControllers: [BrowserWindowController] = []
    private var keyMonitor: Any?
    private var profilesMenu: NSMenu?
    private var privacyMenu: NSMenu?
    private var webRTCProtectionItem: NSMenuItem?
    private var enhancedPrivacyItem: NSMenuItem?
    private var settingsWindowController: AppSettingsWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var updateCheckStatus = "Not checked. Falls back to GitHub Releases when Sparkle is not configured."
    private var didFinishLaunchingAt: Date?
    private var previousRunSummary = "Not recorded"
    private var notificationPermissionStatus = "Not checked"
    private let performanceMonitor = ProcessPerformanceMonitor()
    private let completionNotificationService = CompletionNotificationService(
        scheduler: SystemCompletionNotificationScheduler()
    )
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    private var sparkleStatus = "Disabled: Info.plist has no SUFeedURL / SUPublicEDKey"
    private(set) var profileMutationInProgress = false
    private var profileSwitchInProgress = false
    private var cookieConsentMutationGeneration = 0
    /// Tracks asynchronous consent-cookie mutations started from settings. Destructive profile
    /// operations drain this group before removing a WebKit data store so late callbacks cannot
    /// recreate data in a store that was just deleted.
    private let cookieConsentOperationGroup = DispatchGroup()
    private enum PendingDataMutationKind {
        static let deleteProfile = "delete-profile"
        static let resetDefault = "reset-default"
        static let burn = "burn"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RemoteImageLoader.cleanupStaleTemporaryFiles()
        let smokeTestRun = SmokeTestEnvironment.isEnabled
        didFinishLaunchingAt = Date()
        if smokeTestRun {
            previousRunSummary = "smoke test run"
        } else {
            capturePreviousRunState()
            markRunStarted()
        }
        performanceMonitor.start()
        NetworkStatusMonitor.shared.start()
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationPermissionStatus()
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        configureSparkleUpdaterIfAvailable()
        installKeyboardZoomShortcuts()
        if !smokeTestRun { configureQuickWindowHotKey() }
        let needsIsolationFallbackNotice = smokeTestRun ? false : reconcileProfileIsolationOnLaunch()
        let pendingMutation = !smokeTestRun && ProfileStore.pendingDataMutation != nil
        if !smokeTestRun && !pendingMutation {
            ProfileStore.applyStartupProfileIfAvailable()
            ProfileStore.ensurePrivacyBaseline()
        }

        let profile = smokeTestRun || pendingMutation ? nil : ProfileStore.currentProfile()
        let controller = BrowserWindowController(
            initialURL: smokeTestRun
                ? chatGPTURL
                : (pendingMutation ? nil : ProfileStore.homepageURL(for: profile?.id ?? defaultProfileID)),
            title: profile.map(mainWindowTitle(for:)) ?? (pendingMutation ? "Recovering profile data…" : "ChatGPT Swift Smoke Test"),
            isPopup: false,
            persistent: !smokeTestRun && !pendingMutation,
            profileID: profile?.id
        )
        mainController = controller
        if !pendingMutation {
            controller.show()
        }
        NSApp.activate(ignoringOtherApps: true)
        if pendingMutation {
            reconcilePendingDataMutation()
        }
        if !pendingMutation {
            scheduleSmokeTestIfRequested()
        }

        if !smokeTestRun,
           BrowserPerformancePolicy.shouldRefreshExitTimezoneCache(
               hasExplicitFingerprint: ProfileStore.fingerprint(for: profile?.id) != nil
           ) {
            refreshExitTimezoneCache()
        }

        if needsIsolationFallbackNotice {
            DispatchQueue.main.async { [weak self] in
                self?.presentIsolationFallbackNotice()
            }
        }
    }

    private func reconcileProfileIsolationOnLaunch() -> Bool {
        if #available(macOS 14.0, *) {
            return false
        }
        let currentID = ProfileStore.currentProfileID()
        guard currentID != defaultProfileID else {
            return false
        }
        ProfileStore.setCurrentProfileID(defaultProfileID)
        return true
    }

    /// Completes a destructive data operation that was journaled before WebKit was asked to
    /// mutate a persistent store. The journal is intentionally tiny and contains only an operation
    /// kind plus profile ID; it lets a crash between WebKit and UserDefaults converge safely on the
    /// next launch instead of leaving a ghost profile or stale metadata.
    private func reconcilePendingDataMutation() {
        guard let pending = ProfileStore.pendingDataMutation else {
            return
        }

        switch pending.kind {
        case PendingDataMutationKind.deleteProfile:
            reconcilePendingProfileDeletion(profileID: pending.profileID)
        case PendingDataMutationKind.resetDefault:
            reconcilePendingDefaultReset()
        case PendingDataMutationKind.burn:
            reconcilePendingBurn(profileID: pending.profileID)
        default:
            ProfileStore.clearPendingDataMutation()
            rebuildMainController()
        }
    }

    private func reconcilePendingProfileDeletion(profileID: String) {
        guard #available(macOS 14.0, *) else {
            ProfileStore.clearPendingDataMutation()
            rebuildMainController()
            return
        }
        guard profileID != defaultProfileID,
              let identifier = UUID(uuidString: profileID) else {
            ProfileStore.clearPendingDataMutation()
            rebuildMainController()
            return
        }
        guard ProfileStore.loadProfiles().contains(where: { $0.id == profileID }) else {
            ProfileStore.clearPendingDataMutation()
            rebuildMainController()
            return
        }

        profileMutationInProgress = true
        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            BrowserWindowController.disposeControllers(for: profileID) { [weak self] in
                guard let self else { return }
                let wasCurrent = ProfileStore.currentProfileID() == profileID
                if wasCurrent {
                    ProfileStore.setCurrentProfileID(defaultProfileID)
                    self.rebuildMainController()
                }
                WKWebsiteDataStore.remove(forIdentifier: identifier) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            if wasCurrent {
                                ProfileStore.setCurrentProfileID(profileID)
                            }
                            ProfileStore.clearPendingDataMutation()
                            self.profileMutationInProgress = false
                            self.rebuildMainController()
                            self.presentError("The previous profile deletion did not finish. Profile settings were preserved: \(error.localizedDescription)")
                            return
                        }
                        self.finalizeProfileDeletion(profileID: profileID)
                        ProfileStore.clearPendingDataMutation()
                        self.profileMutationInProgress = false
                        self.applyCurrentCookiePreferenceAfterMutation()
                        self.presentInfo("Completed the previously interrupted profile deletion.")
                    }
                }
            }
        }
    }

    private func reconcilePendingDefaultReset() {
        profileMutationInProgress = true
        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            BrowserWindowController.disposeControllers(for: defaultProfileID) { [weak self] in
                guard let self else { return }
                WebsiteDataCleaner.removeAllData(from: WKWebsiteDataStore.default()) { [weak self] in
                    guard let self else { return }
                    ProfileStore.resetDefaultProfile()
                    ProfileStore.clearPendingDataMutation()
                    self.profileMutationInProgress = false
                    self.applyCurrentCookiePreferenceAfterMutation()
                    self.profilesMenu.map(self.rebuildProfilesMenu(_:))
                    self.rebuildMainController()
                    self.presentInfo("Completed the previously interrupted built-in profile reset.")
                }
            }
        }
    }

    private func reconcilePendingBurn(profileID: String) {
        guard ProfileStore.loadProfiles().contains(where: { $0.id == profileID }) else {
            ProfileStore.clearPendingDataMutation()
            rebuildMainController()
            return
        }
        profileMutationInProgress = true
        let dataStore: WKWebsiteDataStore
        if profileID == defaultProfileID {
            dataStore = .default()
        } else if #available(macOS 14.0, *), let identifier = UUID(uuidString: profileID) {
            dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        } else {
            ProfileStore.clearPendingDataMutation()
            profileMutationInProgress = false
            rebuildMainController()
            return
        }
        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            BrowserWindowController.disposeControllers(for: profileID) { [weak self] in
                guard let self else { return }
                WebsiteDataCleaner.removeAllData(from: dataStore) { [weak self] in
                    guard let self else { return }
                    ProfileSessionStore.clear(profileID: profileID)
                    PromptDraftStore.clearDraft(for: profileID)
                    ProfileStore.disableFingerprint(for: profileID)
                    ProfileStore.clearPendingDataMutation()
                    self.profileMutationInProgress = false
                    self.applyCurrentCookiePreferenceAfterMutation()
                    self.rebuildMainController()
                    self.presentInfo("Completed the previously interrupted profile cleanup.")
                }
            }
        }
    }

    private func presentIsolationFallbackNotice() {
        let alert = NSAlert()
        alert.messageText = "Returned to Default Profile"
        alert.informativeText = "Multiple isolated profiles require macOS 14 or later. This system does not support isolation, so the app switched to the built-in profile to prevent profiles from sharing local data.\n\nUpgrade to macOS 14 or later to use isolated profiles."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !profileMutationInProgress, ProfileStore.pendingDataMutation == nil {
            mainController?.show()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        QuickWindowHotKey.shared.stop()
        NetworkStatusMonitor.shared.stop()
        markRunEndedCleanly()
        performanceMonitor.stop()
        mainController?.persistMainWindowFrame()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func capturePreviousRunState() {
        let defaults = UserDefaults.standard
        let started = defaults.object(forKey: lastRunStartedAtDefaultsKey) as? Date
        let ended = defaults.object(forKey: lastRunEndedAtDefaultsKey) as? Date
        let hadCleanFlag = defaults.object(forKey: lastRunCleanExitDefaultsKey) != nil
        let clean = defaults.bool(forKey: lastRunCleanExitDefaultsKey)

        guard let started else {
            previousRunSummary = "First run or no history"
            return
        }

        if hadCleanFlag, clean {
            previousRunSummary = "Clean exit; started \(Self.timestampString(started)), ended \(ended.map(Self.timestampString) ?? "Unknown")"
        } else {
            previousRunSummary = "Possible unexpected exit; last started \(Self.timestampString(started))"
        }
    }

    private func markRunStarted() {
        let defaults = UserDefaults.standard
        defaults.set(processStartedAt, forKey: lastRunStartedAtDefaultsKey)
        defaults.removeObject(forKey: lastRunEndedAtDefaultsKey)
        defaults.set(false, forKey: lastRunCleanExitDefaultsKey)
    }

    private func markRunEndedCleanly() {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastRunEndedAtDefaultsKey)
        defaults.set(true, forKey: lastRunCleanExitDefaultsKey)
    }

    private func refreshNotificationPermissionStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.notificationPermissionStatus = Self.notificationStatusText(settings.authorizationStatus)
                if settings.authorizationStatus == .denied, BackgroundCompletionNotifications.isEnabled() {
                    BackgroundCompletionNotifications.setEnabled(false)
                }
                self.refreshNativeUtilityWindows()
            }
        }
    }

    private static func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional authorization"
        case .ephemeral:
            return "Ephemeral authorization"
        @unknown default:
            return "Unknown"
        }
    }

    private func configureSparkleUpdaterIfAvailable() {
        guard Self.hasSparkleConfiguration() else {
            sparkleUpdaterController = nil
            sparkleStatus = "Disabled: Info.plist has no SUFeedURL / SUPublicEDKey"
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        sparkleUpdaterController = controller
        sparkleStatus = "Enabled: Sparkle checks automatically on its own schedule"
    }

    private static func hasSparkleConfiguration() -> Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme?.lowercased() == "https",
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }

    func postBackgroundCompletionNotification(from controller: BrowserWindowController) {
        completionNotificationService.postIfAuthorized(
            enabled: BackgroundCompletionNotifications.isEnabled(),
            context: controller.notificationContextText()
        ) { [weak self] outcome in
            switch outcome {
            case .notAuthorized(let status):
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.notificationPermissionStatus = Self.notificationStatusText(status)
                    if status == .denied {
                        BackgroundCompletionNotifications.setEnabled(false)
                    }
                    self.refreshNativeUtilityWindows()
                }
            case .failed(let message):
                browserLogger.error("Failed to post background completion notification: \(message, privacy: .public)")
            case .disabled, .scheduled:
                break
            }
        }
    }

    private static func notificationStatusText(_ status: CompletionNotificationAuthorization) -> String {
        switch status {
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional authorization"
        case .ephemeral:
            return "Ephemeral authorization"
        case .unknown:
            return "Unknown"
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ChatGPT Swift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openAppSettingsAction(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let updateItem = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit ChatGPT Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let importCookiesItem = fileMenu.addItem(withTitle: "Import Cookies...", action: #selector(importCookiesMenu(_:)), keyEquivalent: "")
        importCookiesItem.target = self
        let pasteCookiesItem = fileMenu.addItem(withTitle: "Paste Cookies...", action: #selector(pasteCookiesMenu(_:)), keyEquivalent: "")
        pasteCookiesItem.target = self
        let exportCookiesItem = fileMenu.addItem(withTitle: "Export Cookies...", action: #selector(exportCookiesMenu(_:)), keyEquivalent: "")
        exportCookiesItem.target = self
        let clearWebsiteDataItem = fileMenu.addItem(withTitle: "Clear Current Profile Data...", action: #selector(burnCurrentProfileData(_:)), keyEquivalent: "")
        clearWebsiteDataItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        let goToURLItem = fileMenu.addItem(withTitle: "Go to URL...", action: #selector(goToURLAction(_:)), keyEquivalent: "l")
        goToURLItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        let profilesItem = fileMenu.addItem(withTitle: "Profiles", action: nil, keyEquivalent: "")
        let profilesSubmenu = NSMenu(title: "Profiles")
        profilesSubmenu.delegate = self
        profilesSubmenu.autoenablesItems = false
        profilesItem.submenu = profilesSubmenu
        profilesMenu = profilesSubmenu
        let incognitoItem = fileMenu.addItem(withTitle: "New Private Window", action: #selector(openIncognitoWindow(_:)), keyEquivalent: "n")
        incognitoItem.keyEquivalentModifierMask = [.command, .shift]
        incognitoItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let restoreDraftItem = editMenu.addItem(withTitle: "Restore Saved Draft for This Page", action: #selector(restoreSavedDraftAction(_:)), keyEquivalent: "")
        restoreDraftItem.target = self
        let clearDraftItem = editMenu.addItem(withTitle: "Clear Local Drafts for Current Profile", action: #selector(clearSavedDraftAction(_:)), keyEquivalent: "")
        clearDraftItem.target = self
        editMenu.addItem(.separator())
        let notesContextItem = editMenu.addItem(withTitle: "Insert Selected Note", action: #selector(insertNotesContextAction(_:)), keyEquivalent: "")
        notesContextItem.target = self
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let navigationItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "Navigate")
        let focusPromptItem = navigationMenu.addItem(withTitle: "Focus Input", action: #selector(focusPromptAction(_:)), keyEquivalent: "i")
        focusPromptItem.keyEquivalentModifierMask = [.command, .option]
        focusPromptItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let backItem = navigationMenu.addItem(withTitle: "Back", action: #selector(goBackAction(_:)), keyEquivalent: "[")
        backItem.target = self
        let forwardItem = navigationMenu.addItem(withTitle: "Forward", action: #selector(goForwardAction(_:)), keyEquivalent: "]")
        forwardItem.target = self
        let homeItem = navigationMenu.addItem(withTitle: "Home", action: #selector(goHomeAction(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        homeItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let reloadItem = navigationMenu.addItem(withTitle: "Reload", action: #selector(reloadAction(_:)), keyEquivalent: "r")
        reloadItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let openInBrowserItem = navigationMenu.addItem(withTitle: "Open in Default Browser", action: #selector(openCurrentURLInBrowserAction(_:)), keyEquivalent: "o")
        openInBrowserItem.keyEquivalentModifierMask = [.command, .option]
        openInBrowserItem.target = self
        let copyURLItem = navigationMenu.addItem(withTitle: "Copy Page Link", action: #selector(copyCurrentURLAction(_:)), keyEquivalent: "c")
        copyURLItem.keyEquivalentModifierMask = [.command, .shift]
        copyURLItem.target = self
        navigationItem.submenu = navigationMenu
        mainMenu.addItem(navigationItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let zoomInItem = viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomInAction(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        let zoomOutItem = viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutAction(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        let resetZoomItem = viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoomAction(_:)), keyEquivalent: "0")
        resetZoomItem.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let privacyItem = NSMenuItem()
        let privacyMenu = NSMenu(title: "Privacy")
        privacyMenu.delegate = self
        privacyMenu.autoenablesItems = false
        rebuildPrivacyMenu(privacyMenu)
        privacyItem.submenu = privacyMenu
        self.privacyMenu = privacyMenu
        mainMenu.addItem(privacyItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let quickItem = windowMenu.addItem(withTitle: "Quick Window", action: #selector(showQuickWindow(_:)), keyEquivalent: "")
        quickItem.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let diagnosticsItem = helpMenu.addItem(withTitle: "Diagnostics…", action: #selector(showDiagnosticsWindow(_:)), keyEquivalent: "")
        diagnosticsItem.target = self
        let releaseItem = helpMenu.addItem(withTitle: "Open Release Page", action: #selector(openReleasePageAction(_:)), keyEquivalent: "")
        releaseItem.target = self
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func installKeyboardZoomShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.profileMutationInProgress,
                  ProfileStore.pendingDataMutation == nil else {
                return event
            }
            guard let controller = BrowserWindowController.keyWindowController() else {
                return event
            }

            if Self.isCommandShiftShortcut(event),
               event.charactersIgnoringModifiers?.lowercased() == "h" {
                controller.goHome(nil)
                return nil
            }

            guard Self.isCommandOnlyShortcut(event) else {
                return event
            }

            switch event.charactersIgnoringModifiers {
            case ",":
                self.openAppSettingsAction(nil)
                return nil
            case "[":
                controller.goBack(nil)
                return nil
            case "]":
                controller.goForward(nil)
                return nil
            case "=", "+":
                controller.zoomIn(nil)
                return nil
            case "-":
                controller.zoomOut(nil)
                return nil
            case "0":
                controller.resetZoom(nil)
                return nil
            default:
                return event
            }
        }
    }

    private static func isCommandOnlyShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }

    private static func isCommandShiftShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && flags.contains(.shift)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }

    @objc func openAppSettingsAction(_ sender: Any?) {
        let controller: AppSettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            controller = AppSettingsWindowController(
                state: makeAppSettingsState(),
                callbacks: AppSettingsCallbacks(
                    setPromptDraftRestore: { [weak self] enabled in
                        self?.setPromptDraftRestoreFromSettings(enabled)
                    },
                    setBackgroundCompletionNotifications: { [weak self] enabled in
                        self?.setBackgroundCompletionNotificationsFromSettings(enabled)
                    },
                    setWebRTCProtection: { [weak self] enabled in
                        self?.setWebRTCProtectionFromSettings(enabled)
                    },
                    setRejectNonEssentialCookies: { [weak self] enabled in
                        self?.setRejectNonEssentialCookiesFromSettings(enabled)
                    },
                    setThirdPartyLinksInApp: { [weak self] enabled in
                        self?.setThirdPartyLinksInAppFromSettings(enabled)
                    },
                    setWindowTitleDisplayMode: { [weak self] mode in
                        self?.setWindowTitleDisplayModeFromSettings(mode)
                    },
                    setEnhancedPrivacy: { [weak self] enabled in
                        self?.setEnhancedPrivacyFromSettings(enabled)
                    },
                    openNotesAutomationPrivacy: { [weak self] in
                        self?.openNotesAutomationPrivacy()
                    },
                    showDiagnostics: { [weak self] in
                        self?.showDiagnosticsWindow(nil)
                    },
                    checkForUpdates: { [weak self] in
                        self?.checkForUpdatesFromUserAction(nil)
                    },
                    openReleasePage: { [weak self] in
                        self?.openReleasePage()
                    },
                    setAutoOpenFinderAfterDownload: { enabled in UserDefaults.standard.set(enabled, forKey: "ChatGPTSwiftWeb.DownloadCenter.AutoOpenFinder") },
                    clearCurrentDraft: { [weak self] in
                        BrowserWindowController.clearProfileDrafts(profileID: ProfileStore.currentProfileID())
                        self?.refreshNativeUtilityWindows()
                    },
                    setQuickWindowEnabled: { [weak self] enabled in Task { @MainActor in self?.setQuickWindowEnabled(enabled) } },
                    setQuickWindowShortcut: { [weak self] shortcut in Task { @MainActor in self?.setQuickWindowShortcut(shortcut) } },
                    showDownloads: { [weak self] in Task { @MainActor in self?.mainController?.showDownloads(nil) } }

                )
            )
            settingsWindowController = controller
        }

        controller.update(state: makeAppSettingsState())
        if let window = controller.window {
            if !window.isVisible {
                window.center()
            }
            window.makeKeyAndOrderFront(sender)
        } else {
            controller.showWindow(sender)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPreferencesWindow(_ sender: Any?) {
        openAppSettingsAction(sender)
    }

    @objc private func showDiagnosticsWindow(_ sender: Any?) {
        let controller: DiagnosticsWindowController
        if let existing = diagnosticsWindowController {
            controller = existing
        } else {
            controller = DiagnosticsWindowController(
                state: makeDiagnosticsState(),
                callbacks: AppDiagnosticsCallbacks(
                    refresh: { [weak self] in
                        self?.makeDiagnosticsState() ?? AppDiagnosticsState(generatedAt: "unknown", report: "AppDelegate unavailable")
                    },
                    exportPackage: { [weak self] state in
                        self?.exportDiagnosticsPackage(state)
                    }
                )
            )
            diagnosticsWindowController = controller
        }

        controller.update(state: makeDiagnosticsState())
        controller.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdatesAction(_ sender: Any?) {
        checkForUpdatesFromUserAction(sender)
    }

    @objc private func openReleasePageAction(_ sender: Any?) {
        openReleasePage()
    }

    private func setWebRTCProtectionFromSettings(_ enabled: Bool) {
        guard ensureProfileMetadataWritable() else { return }
        guard PrivacySettings.isWebRTCProtectionEnabled() != enabled else {
            refreshNativeUtilityWindows()
            return
        }
        PrivacySettings.setWebRTCProtectionEnabled(enabled)
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
        refreshNativeUtilityWindows()
    }

    private func setPromptDraftRestoreFromSettings(_ enabled: Bool) {
        guard ensureProfileMetadataWritable() else { return }
        PromptDraftStore.setRestoreEnabled(enabled)
        BrowserWindowController.refreshDraftPreferences()
        refreshNativeUtilityWindows()
    }

    private func setBackgroundCompletionNotificationsFromSettings(_ enabled: Bool) {
        if !enabled {
            BackgroundCompletionNotifications.setEnabled(false)
            refreshNativeUtilityWindows()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error {
                    BackgroundCompletionNotifications.setEnabled(false)
                    self?.notificationPermissionStatus = "Request failed: \(error.localizedDescription)"
                    self?.presentError("Notification permission request failed: \(error.localizedDescription)")
                } else {
                    BackgroundCompletionNotifications.setEnabled(granted)
                    self?.notificationPermissionStatus = granted ? "Authorized" : "Not authorized"
                    if !granted {
                        self?.presentError("Notification permission was not granted. Enable notifications for ChatGPT Swift in System Settings > Notifications.")
                    }
                }
                self?.refreshNativeUtilityWindows()
            }
        }
    }

    private func setThirdPartyLinksInAppFromSettings(_ enabled: Bool) {
        PrivacySettings.setKeepThirdPartyLinksInApp(enabled)
        refreshNativeUtilityWindows()
    }

    private func setRejectNonEssentialCookiesFromSettings(_ enabled: Bool) {
        guard ensureProfileMetadataWritable() else { return }
        CookieConsentSettings.setEnabled(enabled)
        cookieConsentMutationGeneration &+= 1
        let generation = cookieConsentMutationGeneration
        applyCookiePreference(enabled: enabled, generation: generation)
    }

    private func applyCookiePreference(enabled: Bool, generation: Int) {
        guard !profileMutationInProgress else {
            return
        }
        let stores = activePersistentDataStores()
        let group = DispatchGroup()
        let operationGroup = cookieConsentOperationGroup
        for store in stores {
            group.enter()
            operationGroup.enter()
            var didFinish = false
            let finish = {
                guard !didFinish else { return }
                didFinish = true
                operationGroup.leave()
                group.leave()
            }
            if enabled {
                CookieConsentSettings.applyIfEnabled(to: store, completion: finish)
            } else {
                CookieConsentSettings.clearManagedRejectionCookies(from: store, completion: finish)
            }
        }
        group.notify(queue: .main) { [weak self, weak controller = mainController] in
            guard let self else { return }
            guard !self.profileMutationInProgress else {
                return
            }
            guard self.cookieConsentMutationGeneration == generation else {
                self.applyCookiePreference(
                    enabled: CookieConsentSettings.isEnabled(),
                    generation: self.cookieConsentMutationGeneration
                )
                return
            }
            if enabled {
                controller?.showToast("Nonessential cookies are now rejected by default. This applies to all profiles on their next load")
            } else {
                controller?.showToast("Default rejection disabled. Choose in Cookie Preferences when each profile next loads")
            }
            // Consent writes complete asynchronously and can finish after a navigation
            // failure. Recompute the toolbar status so this informational message cannot
            // hide an HTTP error or an active Cloudflare challenge.
            controller?.updateNativeChromeStatus()
            self.refreshNativeUtilityWindows()
        }
    }

    /// New preference mutations are blocked while `profileMutationInProgress` is true, so this
    /// drain gives destructive cleanup a stable boundary around all already-issued WebKit calls.
    private func waitForCookieConsentOperations(completion: @escaping () -> Void) {
        cookieConsentOperationGroup.notify(queue: .main, execute: completion)
    }

    private func invalidateCookiePreferenceMutations() {
        cookieConsentMutationGeneration &+= 1
    }

    private func applyCurrentCookiePreferenceAfterMutation() {
        guard !profileMutationInProgress else {
            return
        }
        cookieConsentMutationGeneration &+= 1
        applyCookiePreference(
            enabled: CookieConsentSettings.isEnabled(),
            generation: cookieConsentMutationGeneration
        )
    }

    private func activePersistentDataStores() -> [WKWebsiteDataStore] {
        var stores = [WKWebsiteDataStore.default()]
        guard #available(macOS 14.0, *) else {
            return stores
        }

        var seen = Set<UUID>()
        for profile in ProfileStore.loadProfiles() where profile.id != defaultProfileID {
            guard let identifier = UUID(uuidString: profile.id), seen.insert(identifier).inserted else {
                continue
            }
            stores.append(WKWebsiteDataStore(forIdentifier: identifier))
        }
        return stores
    }

    private func setWindowTitleDisplayModeFromSettings(_ mode: WindowTitleDisplayMode) {
        WindowTitleSettings.setMode(mode)
        BrowserWindowController.refreshWindowTitles()
        refreshNativeUtilityWindows()
    }

    private func setEnhancedPrivacyFromSettings(_ enabled: Bool) {
        guard ensureProfileMetadataWritable() else { return }
        let profileID = ProfileStore.currentProfileID()
        guard ProfileStore.isEnhancedPrivacyEnabled(for: profileID) != enabled else {
            refreshNativeUtilityWindows()
            return
        }
        ProfileStore.setEnhancedPrivacyEnabled(enabled, for: profileID)
        updateEnhancedPrivacyMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
        refreshNativeUtilityWindows()
    }

    func refreshNativeUtilityWindows() {
        settingsWindowController?.update(state: makeAppSettingsState())
        diagnosticsWindowController?.update(state: makeDiagnosticsState())
    }

    private func scheduleSmokeTestIfRequested() {
        guard let rawPath = SmokeTestEnvironment.reportPath else {
            return
        }

        let timeout = ProcessInfo.processInfo.environment[smokeTimeoutEnvironmentKey].flatMap(Double.init) ?? 25
        let boundedTimeout = min(max(timeout, 5), 120)
        let reportURL = URL(fileURLWithPath: rawPath)
        let deadline = Date().addingTimeInterval(boundedTimeout)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runSmokeTestAttempt(reportURL: reportURL, deadline: deadline)
        }
    }

    private func runSmokeTestAttempt(reportURL: URL, deadline: Date) {
        guard let controller = mainController else {
            finishSmokeTest(reportURL: reportURL, passed: false, report: "mainController=nil")
            return
        }

        controller.runSmokeTestProbe { [weak self] passed, report in
            guard let self else {
                return
            }
            if passed || Date() >= deadline {
                self.finishSmokeTest(reportURL: reportURL, passed: passed, report: report)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runSmokeTestAttempt(reportURL: reportURL, deadline: deadline)
            }
        }
    }

    private func finishSmokeTest(reportURL: URL, passed: Bool, report: String) {
        let status = passed ? "pass" : "fail"
        let body = """
        SMOKE_STATUS=\(status)
        generatedAt=\(Self.timestampString(Date()))
        \(report)
        """

        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: reportURL, atomically: true, encoding: .utf8)
        } catch {
            browserLogger.error("Failed to write smoke test report: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.terminate(nil)
    }

    private func openNotesAutomationPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openReleasePage() {
        NSWorkspace.shared.open(releasePageURL)
    }

    private func checkForUpdatesFromUserAction(_ sender: Any?) {
        if let sparkleUpdaterController {
            updateCheckStatus = "Sparkle is checking for updates; \(sparkleStatus). Current version: \(Self.appVersionText())."
            refreshNativeUtilityWindows()
            sparkleUpdaterController.checkForUpdates(sender)
            return
        }

        checkForUpdates(showAlert: true)
    }

    private func checkForUpdates(showAlert: Bool) {
        updateCheckStatus = "Checking GitHub Releases…"
        refreshNativeUtilityWindows()

        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPTSwiftWeb", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    self.updateCheckStatus = "Check failed: \(error.localizedDescription)"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                    return
                }

                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0
                let responseHost = httpResponse?.url?.host?.lowercased()
                guard statusCode == 200,
                      httpResponse?.url?.scheme?.lowercased() == "https",
                      responseHost == "api.github.com",
                      let data,
                      data.count <= 512 * 1024 else {
                    self.updateCheckStatus = "No readable GitHub Release feed (HTTP \(statusCode))."
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    let title = release.name?.isEmpty == false ? release.name! : release.tagName
                    let date = release.publishedAt?.isEmpty == false ? ", published \(release.publishedAt!)" : ""
                    self.updateCheckStatus = "Latest release: \(title)\(date). Current version: \(Self.appVersionText()). \(self.sparkleStatus). GitHub Releases are for manual review only."
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: release.htmlURL != nil)
                    }
                } catch {
                    self.updateCheckStatus = "Could not parse release feed: \(error.localizedDescription)"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                }
            }
        }.resume()
    }

    private func presentUpdateCheckResult(_ message: String, canOpenReleasePage: Bool) {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.informativeText = message
        alert.alertStyle = .informational
        if canOpenReleasePage {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                openReleasePage()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func makeAppSettingsState() -> AppSettingsState {
        let profile = ProfileStore.currentProfile()
        let startupID = ProfileStore.startupProfileID()
        let startupName = ProfileStore.loadProfiles().first(where: { $0.id == startupID })?.name ?? "Default"
        let fingerprintName = ProfileStore.fingerprint(for: profile.id)?.displayName ?? "Default Safari (No Obfuscation)"
        let isolation: String
        if #available(macOS 14.0, *) {
            isolation = profile.id == defaultProfileID ? "Built-in WebView Data Store" : "Isolated WKWebsiteDataStore"
        } else {
            isolation = "This system does not support isolated persistent data stores for multiple profiles"
        }

        return AppSettingsState(
            appVersion: Self.appVersionText(),
            currentProfileName: profile.name,
            startupProfileName: startupName,
            homepage: ProfileStore.homepageURL(for: profile.id).absoluteString,
            promptDraftRestoreEnabled: PromptDraftStore.isRestoreEnabled(),
            promptDraftSummary: PromptDraftStore.draftSummary(for: profile.id),
            backgroundCompletionNotificationsEnabled: BackgroundCompletionNotifications.isEnabled(),
            notificationPermissionStatus: notificationPermissionStatus,
            profileIsolation: isolation,
            fingerprintName: fingerprintName,
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id),
            webRTCProtectionEnabled: PrivacySettings.isWebRTCProtectionEnabled(),
            rejectNonEssentialCookiesEnabled: CookieConsentSettings.isEnabled(),
            keepThirdPartyLinksInApp: PrivacySettings.keepThirdPartyLinksInApp(),
            windowTitleDisplayMode: WindowTitleSettings.mode(),
            notesAutomationStatus: "Requested when needed. macOS asks for permission the first time you insert a selected note.",
            updateStatus: updateCheckStatus,
            distributionStatus: "\(sparkleStatus). This build uses local self-signing. Packaging and installation verify code signing, universal architecture, and the minimum system version. Developer ID and notarization are optional for external distribution.",
            autoOpenFinderAfterDownload: UserDefaults.standard.bool(forKey: "ChatGPTSwiftWeb.DownloadCenter.AutoOpenFinder"),
            networkStatus: MainActor.assumeIsolated { "\(NetworkStatusMonitor.shared.availability.title) · \(NetworkStatusMonitor.shared.interfaceDescription)" },
            quickWindowEnabled: QuickWindowPreferences.isEnabled,
            quickWindowShortcut: QuickWindowPreferences.shortcut.label

        )
    }

    private func makeDiagnosticsState() -> AppDiagnosticsState {
        let generatedAt = Self.timestampString(Date())
        let cloudflareSummary = mainController?.cloudflareDiagnosticsSummary() ?? "Main window unavailable; no Cloudflare events"
        return AppDiagnosticsState(
            generatedAt: generatedAt,
            report: makeDiagnosticsReport(generatedAt: generatedAt),
            cloudflareSummary: cloudflareSummary
        )
    }

    private func exportDiagnosticsPackage(_ state: AppDiagnosticsState) {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics Bundle"
        panel.message = "Exports redacted diagnostics, app logs from the last 10 minutes, and crash reports. Does not read cookies, localStorage, or chat content. Known patterns redact account names, conversation titles, full URLs, email addresses, and your home directory. Review the text before sharing."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "chatgpt-swift-diagnostics-\(Self.filenameTimestamp(Date())).zip"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.writeDiagnosticsPackage(state, to: url)
        }
    }

    private func writeDiagnosticsPackage(_ state: AppDiagnosticsState, to destinationURL: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let fileManager = FileManager.default
                let tempRoot = fileManager.temporaryDirectory
                    .appendingPathComponent("ChatGPTSwiftDiagnostics-\(UUID().uuidString)", isDirectory: true)
                let packageDir = tempRoot.appendingPathComponent("ChatGPT Swift Diagnostics", isDirectory: true)
                try fileManager.createDirectory(at: packageDir, withIntermediateDirectories: true)

                try state.report.write(
                    to: packageDir.appendingPathComponent("diagnostics.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                let manifest = """
                generatedAt: \(state.generatedAt)
                bundleID: \(Bundle.main.bundleIdentifier ?? appBundleIdentifier)
                version: \(Self.appVersionText())
                process: \(ProcessInfo.processInfo.processName)
                note: This package does not intentionally read cookies, localStorage, IndexedDB, or chat transcript content. App diagnostics remove profile names, page titles, and full page URLs; logs and crash reports redact known URL, email, and user-home patterns. Review the text before sharing.
                """
                try manifest.write(
                    to: packageDir.appendingPathComponent("manifest.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                let performanceCSV = self?.performanceMonitor.csvText() ?? "timestamp,cpu_percent_one_core,resident_bytes,footprint_bytes\n"
                try performanceCSV.write(
                    to: packageDir.appendingPathComponent("performance-samples.csv"),
                    atomically: true,
                    encoding: .utf8
                )

                let crashReports = Self.recentCrashReportURLs(limit: 5)
                if !crashReports.isEmpty {
                    let crashReportDir = packageDir.appendingPathComponent("crash-reports", isDirectory: true)
                    try fileManager.createDirectory(at: crashReportDir, withIntermediateDirectories: true)
                    for reportURL in crashReports {
                        let destination = crashReportDir.appendingPathComponent(reportURL.lastPathComponent)
                        let reportData = try Data(contentsOf: reportURL)
                        guard let reportText = String(data: reportData, encoding: .utf8) else {
                            continue
                        }
                        try DiagnosticRedactor.text(reportText).write(
                            to: destination,
                            atomically: true,
                            encoding: .utf8
                        )
                    }
                }

                let logResult = Self.runProcess(
                    executable: "/usr/bin/log",
                    arguments: [
                        "show",
                        "--predicate",
                        "process == \"ChatGPTSwiftWeb\" OR subsystem == \"\(appBundleIdentifier)\"",
                        "--last",
                        "10m",
                        "--style",
                        "compact"
                    ],
                    currentDirectory: nil
                )
                let logText = logResult.output.isEmpty ? logResult.errorOutput : logResult.output
                try DiagnosticRedactor.text(logText).write(
                    to: packageDir.appendingPathComponent("recent-log.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                let zipResult = Self.runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: [
                        "-c",
                        "-k",
                        "--sequesterRsrc",
                        "--keepParent",
                        packageDir.lastPathComponent,
                        destinationURL.path
                    ],
                    currentDirectory: tempRoot
                )
                try fileManager.removeItem(at: tempRoot)

                guard zipResult.exitCode == 0 else {
                    throw NSError(
                        domain: "ChatGPTSwiftWeb.DiagnosticsExport",
                        code: Int(zipResult.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: zipResult.errorOutput.isEmpty ? "ditto packaging failed" : zipResult.errorOutput]
                    )
                }

                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.presentError("Could not export diagnostics bundle: \(error.localizedDescription)")
                }
            }
        }
    }

    private func makeDiagnosticsReport(generatedAt: String) -> String {
        let profile = ProfileStore.currentProfile()
        let fingerprintName = ProfileStore.fingerprint(for: profile.id)?.displayName ?? "Default Safari (No Obfuscation)"
        let profileLabel = DiagnosticRedactor.profileLabel(isDefault: profile.id == defaultProfileID)
        let startupProfileLabel = ProfileStore.startupProfileID() == defaultProfileID
            ? defaultProfileID
            : "<custom-profile>"
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        var sections: [String] = []

        sections.append(Self.diagnosticSection("App", [
            ("Generated At", generatedAt),
            ("Bundle ID", bundle.bundleIdentifier ?? appBundleIdentifier),
            ("Version", Self.appVersionText()),
            ("Process", "\(process.processName) / pid \(process.processIdentifier)"),
            ("System", process.operatingSystemVersionString),
            ("Bundle Path", bundle.bundlePath),
            ("Process Started At", Self.timestampString(processStartedAt)),
            ("App Launch Completed At", didFinishLaunchingAt.map(Self.timestampString) ?? "Unknown"),
            ("Startup to didFinishLaunching", Self.durationString(from: processStartedAt, to: didFinishLaunchingAt)),
            ("Current Uptime", Self.durationString(from: processStartedAt, to: Date())),
            ("Previous Run", previousRunSummary),
            ("Recent Crash Reports", Self.crashReportSummary(limit: 5)),
        ]))

        sections.append(Self.diagnosticSection("Performance Trends", performanceMonitor.diagnosticRows()))

        sections.append(Self.diagnosticSection("Profiles / Privacy", [
            ("Current Profile", profileLabel),
            ("Profile Configuration Recovery", ProfileStore.metadataRecoveryRequired ? "Recovery required; original configuration preserved, writes paused" : "Normal"),
            ("Homepage", DiagnosticRedactor.url(ProfileStore.homepageURL(for: profile.id))),
            ("Startup Profile", startupProfileLabel),
            ("Local Draft Recovery", PromptDraftStore.isRestoreEnabled() ? "On" : "Close"),
            ("Profile Drafts", PromptDraftStore.draftSummary(for: profile.id)),
            ("Reject Nonessential Cookies by Default", CookieConsentSettings.isEnabled() ? "On" : "Close"),
            ("Background Completion Notifications", BackgroundCompletionNotifications.isEnabled() ? "On" : "Close"),
            ("Notification Permission", notificationPermissionStatus),
            ("Fingerprint Preset", fingerprintName),
            ("Enhanced Privacy", ProfileStore.isEnhancedPrivacyEnabled(for: profile.id) ? "On" : "Close"),
            ("WebRTC Protection", PrivacySettings.isWebRTCProtectionEnabled() ? "On" : "Close"),
            ("Open Third-Party Links in App", PrivacySettings.keepThirdPartyLinksInApp() ? "On" : "Close"),
        ]))

        if let controller = mainController {
            sections.append(controller.diagnosticsReport())
        } else {
            sections.append(Self.diagnosticSection("WebView", [("Status", "mainController unavailable")]))
        }

        sections.append(Self.diagnosticSection("Distribution", [
            ("Update Check", updateCheckStatus),
            ("Sparkle", sparkleStatus),
            ("Release Page", releasePageURL.absoluteString),
            ("Signing Policy", "Local self-signing; packaging and installation verify code signing, universal architecture, and the minimum system version."),
            ("Optional External Distribution", "Notarization / stapler are required only for Developer ID distribution; local installation verification is unaffected."),
        ]))

        return DiagnosticRedactor.text(sections.joined(separator: "\n\n"))
    }

    private static func appVersionText() -> String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        default:
            return "Development Build"
        }
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func durationString(from start: Date, to end: Date?) -> String {
        guard let end else {
            return "Unknown"
        }
        return String(format: "%.3fs", max(0, end.timeIntervalSince(start)))
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(exitCode: 127, output: "", errorOutput: error.localizedDescription)
        }

        let outputCollector = ProcessOutputCollector()
        let errorCollector = ProcessOutputCollector()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.drain(outputPipe.fileHandleForReading)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCollector.drain(errorPipe.fileHandleForReading)
            drainGroup.leave()
        }

        process.waitUntilExit()
        drainGroup.wait()
        let output = outputCollector.stringValue
        let errorOutput = errorCollector.stringValue
        return ProcessRunResult(exitCode: process.terminationStatus, output: output, errorOutput: errorOutput)
    }

    private static func recentCrashReportURLs(limit: Int) -> [URL] {
        let diagnosticReportsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let reportURLs = try? FileManager.default.contentsOfDirectory(
            at: diagnosticReportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return reportURLs
            .filter { url in
                let name = url.lastPathComponent
                return name.contains("ChatGPTSwiftWeb")
                    && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
            }
            .sorted { lhs, rhs in
                Self.fileModificationDate(lhs) > Self.fileModificationDate(rhs)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func crashReportSummary(limit: Int) -> String {
        let reports = recentCrashReportURLs(limit: limit)
        guard !reports.isEmpty else {
            return "None"
        }
        return reports.map { url in
            "\(url.lastPathComponent) (\(Self.timestampString(Self.fileModificationDate(url))))"
        }.joined(separator: "\n")
    }

    private static func fileModificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private static func diagnosticSection(_ title: String, _ rows: [(String, String)]) -> String {
        let body = rows.map { key, value in
            "\(key): \(value)"
        }.joined(separator: "\n")
        return "[\(title)]\n\(body)"
    }

    @objc private func importCookiesMenu(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        mainController?.importCookiesFromPanel()
    }

    @objc private func pasteCookiesMenu(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        mainController?.pasteCookiesFromDialog()
    }

    @objc private func exportCookiesMenu(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        mainController?.exportCookiesViaPanel()
    }

    @objc private func burnCurrentProfileData(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        guard let controller = mainController else { return }
        profileMutationInProgress = true
        invalidateCookiePreferenceMutations()
        // Drain any settings-triggered cookie writes before presenting the destructive action.
        // `profileMutationInProgress` blocks new batches while the confirmation sheet is open.
        waitForCookieConsentOperations { [weak self, weak controller] in
            guard let self, let controller, self.profileMutationInProgress else { return }
            controller.confirmBurnCurrentProfileData(onCancel: { [weak self] in
                self?.profileMutationInProgress = false
                self?.applyCurrentCookiePreferenceAfterMutation()
            }) { [weak self] in
                guard let self else {
                    return
                }
                let profileID = ProfileStore.currentProfileID()
                ProfileSessionStore.clear(profileID: profileID)
                PromptDraftStore.clearDraft(for: profileID)
                ProfileStore.disableFingerprint(for: profileID)
                ProfileStore.clearPendingDataMutation()
                self.profileMutationInProgress = false
                self.applyCurrentCookiePreferenceAfterMutation()
                self.rebuildMainController()
                self.presentInfo("Cleared browsing data for this profile and restored the default Safari fingerprint. Profile name, homepage, and enhanced privacy settings were preserved.")
            }
        }
    }

    @objc private func toggleWebRTCProtection(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let enabled = !PrivacySettings.isWebRTCProtectionRequested()
        PrivacySettings.setWebRTCProtectionEnabled(enabled)
        updateWebRTCProtectionMenuItem()

        let currentURL = mainController?.currentURL()
        rebuildMainController(initialURL: currentURL)
    }

    @objc private func toggleThirdPartyLinksInApp(_ sender: NSMenuItem) {
        let enabled = !PrivacySettings.keepThirdPartyLinksInApp()
        PrivacySettings.setKeepThirdPartyLinksInApp(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func showPrivacyStatus(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let fingerprint = ProfileStore.fingerprint(for: profile.id)
        let fingerprintText = fingerprint?.displayName ?? "Default Safari (No Obfuscation)"
        let enhancedPrivacyText = ProfileStore.isEnhancedPrivacyEnabled(for: profile.id) ? "On" : "Close"
        let webRTCText = PrivacySettings.isWebRTCProtectionEnabled() ? "On" : "Close"
        let assessment = FingerprintCatalog.privacyAssessment(
            fingerprint: fingerprint,
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id),
            webRTCProtectionEnabled: PrivacySettings.isWebRTCProtectionEnabled()
        )
        let isolation: String
        if #available(macOS 14.0, *) {
            isolation = profile.id == defaultProfileID ? "The built-in profile uses this app's default WebView data store" : "This profile uses an isolated WKWebsiteDataStore"
        } else {
            isolation = "This system does not support isolated persistent data stores for multiple profiles"
        }

        let alert = NSAlert()
        alert.messageText = "Privacy Status"
        alert.informativeText = """
        Current Profile: \(profile.name)
        Data Isolation: \(isolation)
        Fingerprint Preset: \(fingerprintText)
        Enhanced Privacy: \(enhancedPrivacyText)
        WebRTC Protection: \(webRTCText)
        GPC: JavaScript signal enabled; Sec-GPC enabled for main navigation requests
        URL tracking parameter removal: enabled for top-level navigation only
        Referrer control: enabled; cross-site top-level navigation retains at most the source origin
        Accept-Language: overridden in JavaScript; app-initiated top-level navigation uses the profile language header. Subresources are controlled by WKWebView / the system
        Tracker blocking: disabled

        Consistency Assessment:
        \(assessment)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openFingerprintTestPage(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        mainController?.loadFingerprintTestPage()
    }

    @objc private func goToURLAction(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        guard let controller = mainController else {
            return
        }
        let initial = controller.currentURL()?.absoluteString ?? ""
        promptForURL(
            title: "Go to URL",
            message: "Enter an https:// URL. It will load in the current profile, with cookies and login sessions isolated from other profiles.",
            initial: initial
        ) { [weak self] url in
            guard let self, let url else {
                return
            }
            self.mainController?.navigate(to: url)
        }
    }

    @objc private func goBackAction(_ sender: Any?) {
        guard !profileMutationInProgress else { return }
        BrowserWindowController.keyWindowController()?.goBack(sender)
    }

    @objc private func goForwardAction(_ sender: Any?) {
        guard !profileMutationInProgress else { return }
        BrowserWindowController.keyWindowController()?.goForward(sender)
    }

    @objc private func goHomeAction(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        (BrowserWindowController.keyWindowController() ?? mainController)?.goHome(sender)
    }

    @objc private func reloadAction(_ sender: Any?) {
        guard !profileMutationInProgress, !ProfileStore.metadataRecoveryRequired else { return }
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        controller.reload(sender)
    }

    @objc private func zoomInAction(_ sender: Any?) {
        (BrowserWindowController.keyWindowController() ?? mainController)?.zoomIn(sender)
    }

    @objc private func zoomOutAction(_ sender: Any?) {
        (BrowserWindowController.keyWindowController() ?? mainController)?.zoomOut(sender)
    }

    @objc private func resetZoomAction(_ sender: Any?) {
        (BrowserWindowController.keyWindowController() ?? mainController)?.resetZoom(sender)
    }

    @objc private func openCurrentURLInBrowserAction(_ sender: Any?) {
        (BrowserWindowController.keyWindowController() ?? mainController)?.openCurrentURLInSystemBrowser(sender)
    }

    @objc private func copyCurrentURLAction(_ sender: Any?) {
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController,
              let url = controller.currentURL(),
              let safeURL = NavigationRules.sanitizedUserFacingURL(url, sourceURL: url) else {
            presentError("This page has no HTTPS link that can be safely copied. Temporary login parameters will not be copied to the clipboard.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(safeURL.absoluteString, forType: .string)
        if safeURL != url {
            controller.setStatus("Copied after removing temporary login parameters", showsProgress: false)
        }
    }

    @objc private func setProfileHomepageAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let profile = ProfileStore.currentProfile()
        let initial = ProfileStore.homepageString(for: profile.id) ?? ""
        promptForURL(
            title: "Set Homepage for Profile \"\(profile.name)\"",
            message: "This URL will load on the next launch or switch to this profile. Only https:// is supported. Leave blank to keep the current setting.",
            initial: initial
        ) { [weak self] url in
            guard let self, let url else {
                return
            }
            ProfileStore.setHomepage(url, for: profile.id)
            self.rebuildMainController(initialURL: url)
        }
    }

    @objc private func resetProfileHomepageAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let profile = ProfileStore.currentProfile()
        ProfileStore.removeHomepage(for: profile.id)
        rebuildMainController(initialURL: ProfileStore.homepageURL(for: profile.id))
    }

    @objc private func openIncognitoWindow(_ sender: Any?) {
        let controller = BrowserWindowController(
            initialURL: chatGPTURL,
            title: ProfileWindowTitle.format(
                profileName: "Private",
                isDefault: false,
                mode: WindowTitleSettings.mode()
            ),
            isPopup: true,
            persistent: false,
            profileID: nil,
            closeHandler: { [weak self] in
                self?.incognitoControllers.removeAll { $0.window.isVisible == false }
            }
        )
        incognitoControllers.append(controller)
        controller.show()
    }

    @objc func switchToProfile(_ sender: NSMenuItem) {
        guard ensureProfileMetadataWritable(), !profileSwitchInProgress,
              let id = sender.representedObject as? String,
              ProfileStore.loadProfiles().contains(where: { $0.id == id }), id != ProfileStore.currentProfileID() else { return }
        profileSwitchInProgress = true
        mainController?.showToast("Switching profiles…")
        let finish = { [weak self] in
            guard let self, self.profileSwitchInProgress else { return }
            self.profileSwitchInProgress = false
            guard !self.profileMutationInProgress, ProfileStore.pendingDataMutation == nil else { return }
            self.quickController?.dispose()
            self.quickController = nil
            ProfileStore.setCurrentProfileID(id)
            self.updateWebRTCProtectionMenuItem()
            self.updateEnhancedPrivacyMenuItem()
            self.rebuildMainController(initialURL: ProfileSessionStore.load(profileID: id)?.url)
        }
        if let mainController { mainController.capturePageState(completion: finish) } else { finish() }
    }

    @objc private func setCurrentProfileAsDefaultAction(_ sender: Any?) {
        setProfileAsDefault(id: ProfileStore.currentProfileID())
    }

    @objc private func setProfileAsDefaultAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        setProfileAsDefault(id: id)
    }

    private func setProfileAsDefault(id: String) {
        guard ensureProfileMetadataWritable() else { return }
        guard ProfileStore.setStartupProfileID(id) else {
            presentError("Could not set the startup profile: target profile not found.")
            return
        }
        profilesMenu.map(rebuildProfilesMenu(_:))
        let profileName = ProfileStore.loadProfiles().first(where: { $0.id == id })?.name ?? "Target Profile"
        presentInfo("Set “\(profileName)” as the startup profile.")
    }

    @objc private func selectFingerprintPreset(_ sender: NSMenuItem) {
        guard ensureProfileMetadataWritable() else { return }
        guard let presetID = sender.representedObject as? String else {
            return
        }
        let profileID = ProfileStore.currentProfileID()
        if presetID == FingerprintCatalog.offPresetID {
            ProfileStore.disableFingerprint(for: profileID)
        } else if let preset = FingerprintCatalog.preset(for: presetID) {
            ProfileStore.setFingerprint(preset, for: profileID)
        }
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func randomizeCurrentFingerprint(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let profileID = ProfileStore.currentProfileID()
        ProfileStore.setFingerprint(FingerprintCatalog.randomProfile(), for: profileID)
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func toggleEnhancedPrivacy(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let profileID = ProfileStore.currentProfileID()
        let enabled = !ProfileStore.isEnhancedPrivacyEnabled(for: profileID)
        ProfileStore.setEnhancedPrivacyEnabled(enabled, for: profileID)
        updateEnhancedPrivacyMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func cloneCurrentProfileAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        guard ensureIsolationAvailable() else {
            return
        }
        let source = ProfileStore.currentProfile()
        let defaultName = "\(source.name) Copy"

        let alert = NSAlert()
        alert.messageText = "Clone Current Profile"
        alert.informativeText = "Copies the homepage and enhanced privacy settings and generates a stable random fingerprint. Cookies are not copied unless selected below."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = uniqueProfileName(defaultName)
        textField.placeholderString = "New Profile Name"
        stack.addArrangedSubview(textField)

        let copyCookiesButton = NSButton(checkboxWithTitle: "Also Copy Cookies", target: nil, action: nil)
        copyCookiesButton.state = .off
        stack.addArrangedSubview(copyCookiesButton)

        alert.accessoryView = stack
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        guard !Self.profileNameExists(name, in: ProfileStore.loadProfiles(), excluding: nil) else {
            presentDuplicateNameAlert(name: name)
            return
        }

        createProfileFromCurrent(named: name, copyCookies: copyCookiesButton.state == .on)
    }

    @objc private func exportCurrentProfileAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        panel.message = "Exports the profile name, homepage, fingerprint preset, and enhanced privacy settings. Does not export cookies or website data."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name)-profile.json"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.exportCurrentProfile(to: url)
        }
    }

    @objc private func importProfileAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        guard ensureIsolationAvailable() else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Profile"
        panel.message = "Choose a previously exported profile JSON file. Import creates a new profile without replacing existing profiles."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.importProfile(from: url)
        }
    }

    @objc private func restoreProfileMetadataAction(_ sender: Any?) {
        guard !profileMutationInProgress,
              ProfileStore.pendingDataMutation == nil,
              ProfileStore.metadataRecoveryRequired else {
            return
        }
        guard ProfileStore.restoreProfilesFromBackup() else {
            presentError("No valid profile backup is available for automatic recovery. Export the original backup before resetting the default profile.")
            return
        }
        profilesMenu.map(rebuildProfilesMenu(_:))
        updateWebRTCProtectionMenuItem()
        updateEnhancedPrivacyMenuItem()
        rebuildMainController()
        presentInfo("Restored profile settings from the preserved original backup. Website data was not deleted.")
    }

    @objc private func resetProfileMetadataAfterRecoveryAction(_ sender: Any?) {
        guard !profileMutationInProgress,
              ProfileStore.pendingDataMutation == nil,
              ProfileStore.metadataRecoveryRequired else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset Default Profile Settings?"
        alert.informativeText = "Preserves the original damaged configuration backup and resets only the default profile. No WebKit website data will be deleted. Use “Check Leftover Profile Data” to manage old profiles separately afterward."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Default Profile")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        ProfileStore.resetToDefaultAfterRecovery()
        profilesMenu.map(rebuildProfilesMenu(_:))
        updateWebRTCProtectionMenuItem()
        updateEnhancedPrivacyMenuItem()
        rebuildMainController()
        presentInfo("Reset default profile settings. Website data was preserved.")
    }

    @objc private func exportCorruptProfileMetadataAction(_ sender: Any?) {
        guard let data = ProfileStore.corruptProfilesBackupData else {
            presentError("No original profile configuration backup is available to export.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Original Profile Configuration Backup"
        panel.message = "This file may contain profile names, homepages, and privacy settings. It does not contain cookies or website data."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ChatGPT-Swift-corrupt-profile-backup.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try BrowserDataBoundary.writeSensitiveData(data, to: url)
                self?.presentInfo("Exported the original profile configuration backup.")
            } catch {
                self?.presentError("Could not export original backup: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showFingerprintAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Fingerprint Protection and Its Limits"
        alert.informativeText = """
        Protection: each profile uses a fixed Safari/WebKit fingerprint for common JavaScript signals, including UA, navigator, screen, Intl, touch, Canvas, WebGL, AudioContext, GPC, and WebRTC.

        Recommendation: keep the default Safari fingerprint for everyday use. Select or randomize a profile fingerprint only when you need separate characteristics. Avoid frequent switches between very different devices.

        Cannot hide:
        - TLS fingerprints (JA3 / JA4): WKWebView uses the system network stack, which this app cannot modify per site.
        - HTTP/2 frame ordering and WebKit rendering details: these still reveal the Safari/WebKit engine.
        - Workers, fonts, GPU, window size, and behavior: exposure can be reduced, but hiding these signals is not guaranteed.
        - Network egress: the same network may still link different accounts to the same environment.

        This app provides consistent Safari-only privacy fingerprints. It does not impersonate Chrome or Firefox.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func addProfileAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        guard ensureIsolationAvailable() else {
            return
        }
        promptForName(title: "New Profile", initial: "") { [weak self] name in
            guard let self, let name else {
                return
            }
            var profiles = ProfileStore.loadProfiles()
            if Self.profileNameExists(name, in: profiles, excluding: nil) {
                self.presentDuplicateNameAlert(name: name)
                return
            }
            let profile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
            profiles.append(profile)
            ProfileStore.save(profiles)
            ProfileStore.disableFingerprint(for: profile.id)
            ProfileStore.setEnhancedPrivacyEnabled(false, for: profile.id)
            ProfileStore.setCurrentProfileID(profile.id)
            self.rebuildMainController()
        }
    }

    @objc private func renameCurrentProfileAction(_ sender: Any?) {
        guard ensureProfileMetadataWritable() else { return }
        let currentID = ProfileStore.currentProfileID()
        var profiles = ProfileStore.loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == currentID }) else {
            return
        }
        promptForName(title: "Rename Current Profile", initial: profiles[idx].name) { [weak self] name in
            guard let self, let name else {
                return
            }
            if Self.profileNameExists(name, in: profiles, excluding: currentID) {
                self.presentDuplicateNameAlert(name: name)
                return
            }
            profiles[idx].name = name
            ProfileStore.save(profiles)
            self.mainController?.window.title = self.mainWindowTitle(for: profiles[idx])
            self.mainController?.updateProfileButton()
        }
    }

    private static func profileNameExists(_ name: String, in profiles: [WebProfile], excluding excludedID: String?) -> Bool {
        let normalized = name.lowercased()
        return profiles.contains { profile in
            profile.id != excludedID && profile.name.lowercased() == normalized
        }
    }

    private func presentDuplicateNameAlert(name: String) {
        let alert = NSAlert()
        alert.messageText = "Profile Name Already Exists"
        alert.informativeText = "A profile named “\(name)” already exists. Choose another name."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func deleteCurrentProfileAction(_ sender: Any?) {
        deleteProfile(id: ProfileStore.currentProfileID())
    }

    @objc private func deleteProfileAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        deleteProfile(id: id)
    }

    private func deleteProfile(id: String) {
        guard !ProfileStore.metadataRecoveryRequired else {
            presentError("Cannot read profile settings. The original configuration was preserved. No profile data will be deleted before recovery.")
            return
        }
        let currentID = ProfileStore.currentProfileID()
        let profiles = ProfileStore.loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            presentError("Deletion failed: target profile not found.")
            return
        }
        let profile = profiles[idx]
        if profile.id == defaultProfileID {
            deleteDefaultProfile(profile, isCurrent: currentID == profile.id)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete Profile \"\(profile.name)\"?"
        let startupDefaultNote = profile.id == ProfileStore.startupProfileID()
            ? "\n\nThis is the startup profile. After deletion, startup will return to the built-in profile."
            : ""
        alert.informativeText = "All cookies, login sessions, cache, and local storage for this profile will be permanently deleted. Other profiles are unaffected.\(startupDefaultNote)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard !profileMutationInProgress else {
            return
        }
        profileMutationInProgress = true
        invalidateCookiePreferenceMutations()
        let wasCurrent = currentID == profile.id
        // Close every WebView using this persistent store before asking WebKit to remove it. The
        // metadata is finalized only after WebKit confirms removal; a failed deletion therefore
        // cannot leave a profile pointing at an unknown half-deleted store.
        ProfileStore.markPendingDataMutation(
            kind: PendingDataMutationKind.deleteProfile,
            profileID: profile.id
        )
        guard #available(macOS 14.0, *), let uuid = UUID(uuidString: profile.id) else {
            profileMutationInProgress = false
            ProfileStore.clearPendingDataMutation()
            applyCurrentCookiePreferenceAfterMutation()
            if wasCurrent, ProfileStore.currentProfileID() == defaultProfileID {
                ProfileStore.setCurrentProfileID(profile.id)
                rebuildMainController()
            }
            presentError("This system cannot safely delete the profile's data store. Profile settings were preserved.")
            return
        }
        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            BrowserWindowController.disposeControllers(for: profile.id) { [weak self] in
                guard let self else { return }
                if wasCurrent {
                    ProfileStore.setCurrentProfileID(defaultProfileID)
                    self.rebuildMainController()
                }
                WKWebsiteDataStore.remove(forIdentifier: uuid) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            ProfileStore.clearPendingDataMutation()
                            self.profileMutationInProgress = false
                            self.applyCurrentCookiePreferenceAfterMutation()
                            if wasCurrent, ProfileStore.currentProfileID() == defaultProfileID {
                                ProfileStore.setCurrentProfileID(profile.id)
                                self.rebuildMainController()
                            }
                            self.presentError("Could not delete profile data. Profile settings were preserved: \(error.localizedDescription)")
                            return
                        }
                        self.profileMutationInProgress = false
                        self.finalizeProfileDeletion(profileID: profile.id)
                        ProfileStore.clearPendingDataMutation()
                        self.applyCurrentCookiePreferenceAfterMutation()
                        self.presentInfo("Deleted profile “\(profile.name)” and its website data.")
                    }
                }
            }
        }
    }

    private func finalizeProfileDeletion(profileID: String) {
        var profiles = ProfileStore.loadProfiles()
        profiles.removeAll { $0.id == profileID }
        guard profiles.contains(where: { $0.id == defaultProfileID }) else {
            return
        }
        ProfileSessionStore.clear(profileID: profileID)
        Task { @MainActor in DownloadCenter.shared.forget(profileID: profileID) }
        ProfileStore.removeAllMetadata(for: profileID)
        ProfileStore.save(profiles)
        ProfileStore.clearStartupProfileIfNeeded(profileID)
        profilesMenu.map(rebuildProfilesMenu(_:))
        updateEnhancedPrivacyMenuItem()
        refreshNativeUtilityWindows()
    }

    private func deleteDefaultProfile(_ profile: WebProfile, isCurrent: Bool) {
        let alert = NSAlert()
        alert.messageText = "Delete Built-In Profile \"\(profile.name)\"?"
        alert.informativeText = "The built-in profile uses this app's default WebView data store. Deletion clears its cookies, login sessions, cache, and local storage, then creates a new built-in profile with a fresh name, homepage, fingerprint, and enhanced privacy settings. Other isolated profiles are unaffected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete and Recreate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard !profileMutationInProgress else {
            return
        }
        profileMutationInProgress = true
        invalidateCookiePreferenceMutations()

        ProfileStore.markPendingDataMutation(
            kind: PendingDataMutationKind.resetDefault,
            profileID: defaultProfileID
        )

        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            BrowserWindowController.disposeControllers(for: defaultProfileID) { [weak self] in
                guard let self else { return }
                WebsiteDataCleaner.removeAllData(from: WKWebsiteDataStore.default()) { [weak self] in
                    guard let self else {
                        return
                    }
                    self.profileMutationInProgress = false
                    ProfileSessionStore.clear(profileID: defaultProfileID)
                    PromptDraftStore.clearDraft(for: defaultProfileID)
                    ProfileStore.resetDefaultProfile()
                    ProfileStore.clearPendingDataMutation()
                    ProfileStore.setCurrentProfileID(isCurrent ? defaultProfileID : ProfileStore.currentProfileID())
                    self.applyCurrentCookiePreferenceAfterMutation()
                    self.profilesMenu.map(self.rebuildProfilesMenu(_:))
                    if isCurrent {
                        self.rebuildMainController()
                    }
                    self.presentInfo("Deleted and recreated the built-in profile.")
                }
            }
        }
    }

    @objc private func inspectOrphanedProfileDataStores(_ sender: Any?) {
        guard !profileMutationInProgress else { return }
        guard !ProfileStore.metadataRecoveryRequired else {
            presentError("Cannot read profile settings. The original configuration was preserved. Leftover data will not be checked or cleared before recovery.")
            return
        }
        guard #available(macOS 14.0, *) else {
            presentInfo("Checking leftover profile data requires macOS 14 or later.")
            return
        }

        profileMutationInProgress = true
        invalidateCookiePreferenceMutations()
        waitForCookieConsentOperations { [weak self] in
            guard let self, self.profileMutationInProgress else { return }
            let activeProfileIDs = ProfileStore.loadProfiles().map(\.id)
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { [weak self] allIdentifiers in
                guard let self else {
                    return
                }
                let orphanedIdentifiers = ProfileDataStoreInventory.orphanedIdentifiers(
                    allIdentifiers: allIdentifiers,
                    activeProfileIDs: activeProfileIDs
                )
                guard !orphanedIdentifiers.isEmpty else {
                    self.profileMutationInProgress = false
                    self.applyCurrentCookiePreferenceAfterMutation()
                    self.presentInfo("No leftover website data from deleted profiles was found.")
                    return
                }

                let alert = NSAlert()
                alert.messageText = "Found \(orphanedIdentifiers.count) Leftover Profile Data Stores"
                alert.informativeText = "These WebKit data stores no longer belong to current profiles and may contain cookies, login sessions, cache, and local storage. Cleanup cannot be undone. Your \(activeProfileIDs.count) current profiles will not be deleted."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Clear Leftover Data")
                alert.addButton(withTitle: "Keep")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    self.profileMutationInProgress = false
                    self.applyCurrentCookiePreferenceAfterMutation()
                    return
                }

                self.removeOrphanedProfileDataStores(orphanedIdentifiers[...], removedCount: 0, failedCount: 0)
            }
        }
    }

    @available(macOS 14.0, *)
    private func removeOrphanedProfileDataStores(
        _ remaining: ArraySlice<UUID>,
        removedCount: Int,
        failedCount: Int
    ) {
        guard !ProfileStore.metadataRecoveryRequired else {
            profileMutationInProgress = false
            applyCurrentCookiePreferenceAfterMutation()
            presentError("Profile settings entered recovery mode. Leftover data cleanup stopped.")
            return
        }
        guard let identifier = remaining.first else {
            profileMutationInProgress = false
            applyCurrentCookiePreferenceAfterMutation()
            if failedCount == 0 {
                presentInfo("Cleared \(removedCount) leftover profile data stores. Current profiles are unaffected.")
            } else {
                presentError("Cleared \(removedCount) leftover data stores; \(failedCount) could not be cleared. Quit the app and try again.")
            }
            return
        }

        let stillActive = ProfileStore.loadProfiles().contains { profile in
            UUID(uuidString: profile.id) == identifier
        }
        if stillActive {
            removeOrphanedProfileDataStores(
                remaining.dropFirst(),
                removedCount: removedCount,
                failedCount: failedCount
            )
            return
        }

        WKWebsiteDataStore.remove(forIdentifier: identifier) { [weak self] error in
            DispatchQueue.main.async {
                self?.removeOrphanedProfileDataStores(
                    remaining.dropFirst(),
                    removedCount: removedCount + (error == nil ? 1 : 0),
                    failedCount: failedCount + (error == nil ? 0 : 1)
                )
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === profilesMenu {
            rebuildProfilesMenu(menu)
        } else if menu === privacyMenu {
            rebuildPrivacyMenu(menu)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)):
            return !profileMutationInProgress && (BrowserWindowController.keyWindowController()?.canGoBack ?? false)
        case #selector(goForwardAction(_:)):
            return !profileMutationInProgress && (BrowserWindowController.keyWindowController()?.canGoForward ?? false)
        case #selector(goToURLAction(_:)), #selector(goHomeAction(_:)), #selector(reloadAction(_:)),
             #selector(importCookiesMenu(_:)), #selector(pasteCookiesMenu(_:)), #selector(exportCookiesMenu(_:)),
             #selector(openFingerprintTestPage(_:)), #selector(toggleWebRTCProtection(_:)):
            return !profileMutationInProgress && !ProfileStore.metadataRecoveryRequired && mainController != nil
        case #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(resetZoomAction(_:)):
            return (BrowserWindowController.keyWindowController() ?? mainController) != nil
        case #selector(burnCurrentProfileData(_:)):
            return !profileMutationInProgress && !ProfileStore.metadataRecoveryRequired && mainController != nil
        case #selector(switchToProfile(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return !profileMutationInProgress
                && !ProfileStore.metadataRecoveryRequired
                && canUseProfile(id)
                && id != ProfileStore.currentProfileID()
        case #selector(setProfileAsDefaultAction(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return !profileMutationInProgress
                && !ProfileStore.metadataRecoveryRequired
                && canUseProfile(id)
                && id != ProfileStore.startupProfileID()
        case #selector(setCurrentProfileAsDefaultAction(_:)):
            let currentID = ProfileStore.currentProfileID()
            return !profileMutationInProgress
                && !ProfileStore.metadataRecoveryRequired
                && canUseProfile(currentID)
                && currentID != ProfileStore.startupProfileID()
        case #selector(addProfileAction(_:)), #selector(importProfileAction(_:)):
            return !profileMutationInProgress && !ProfileStore.metadataRecoveryRequired && isProfileIsolationAvailable
        case #selector(renameCurrentProfileAction(_:)):
            return !profileMutationInProgress
                && !ProfileStore.metadataRecoveryRequired
                && (isProfileIsolationAvailable || ProfileStore.currentProfileID() == defaultProfileID)
        case #selector(deleteProfileAction(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return !profileMutationInProgress && !ProfileStore.metadataRecoveryRequired && canDeleteProfile(id)
        case #selector(deleteCurrentProfileAction(_:)):
            return !profileMutationInProgress
                && !ProfileStore.metadataRecoveryRequired
                && canDeleteProfile(ProfileStore.currentProfileID())
        default:
            return menuItem.isEnabled
        }
    }

    private func rebuildProfilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let isolationAvailable = isProfileIsolationAvailable

        if ProfileStore.metadataRecoveryRequired {
            let warning = menu.addItem(withTitle: "Profile Settings Need Recovery (Writes Paused)", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            let restoreItem = menu.addItem(withTitle: "Restore from Preserved Backup…", action: #selector(restoreProfileMetadataAction(_:)), keyEquivalent: "")
            restoreItem.target = self
            restoreItem.isEnabled = !profileMutationInProgress && ProfileStore.pendingDataMutation == nil
            let resetItem = menu.addItem(withTitle: "Reset Default Profile Settings…", action: #selector(resetProfileMetadataAfterRecoveryAction(_:)), keyEquivalent: "")
            resetItem.target = self
            resetItem.isEnabled = !profileMutationInProgress && ProfileStore.pendingDataMutation == nil
            let exportItem = menu.addItem(withTitle: "Export Original Configuration Backup…", action: #selector(exportCorruptProfileMetadataAction(_:)), keyEquivalent: "")
            exportItem.target = self
            menu.addItem(NSMenuItem.separator())
        }

        let currentID = ProfileStore.currentProfileID()
        let defaultID = ProfileStore.startupProfileID()
        let profiles = ProfileStore.loadProfiles()
        for profile in profiles {
            let title = profileMenuTitle(for: profile, currentID: currentID, startupID: defaultID)
            let profileItem = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let profileMenu = NSMenu(title: profile.name)

            let switchItem = profileMenu.addItem(withTitle: "Switch to This Profile", action: #selector(switchToProfile(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.representedObject = profile.id
            switchItem.isEnabled = canUseProfile(profile.id) && profile.id != currentID

            let setDefaultTitle = profile.id == defaultID ? "Already the Startup Profile" : "Set as Startup Profile"
            let setDefaultItem = profileMenu.addItem(withTitle: setDefaultTitle, action: #selector(setProfileAsDefaultAction(_:)), keyEquivalent: "")
            setDefaultItem.target = self
            setDefaultItem.representedObject = profile.id
            setDefaultItem.isEnabled = canUseProfile(profile.id) && profile.id != defaultID

            profileMenu.addItem(NSMenuItem.separator())
            let deleteItem = profileMenu.addItem(withTitle: "Delete This Profile…", action: #selector(deleteProfileAction(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = profile.id
            deleteItem.isEnabled = canDeleteProfile(profile.id)
            if profile.id == defaultProfileID {
                deleteItem.toolTip = "Deleting the built-in profile clears the default WebView data store and immediately creates a new built-in profile."
            }

            profileItem.submenu = profileMenu
        }
        menu.addItem(NSMenuItem.separator())
        let setHomeItem = menu.addItem(withTitle: "Set Profile Homepage…", action: #selector(setProfileHomepageAction(_:)), keyEquivalent: "")
        setHomeItem.target = self
        let setDefaultTitle = currentID == defaultID ? "Already the Startup Profile" : "Set as Startup Profile"
        let setDefaultItem = menu.addItem(withTitle: setDefaultTitle, action: #selector(setCurrentProfileAsDefaultAction(_:)), keyEquivalent: "")
        setDefaultItem.target = self
        setDefaultItem.isEnabled = canUseProfile(currentID) && currentID != defaultID
        menu.addItem(NSMenuItem.separator())
        let addItem = menu.addItem(withTitle: "New Profile…", action: #selector(addProfileAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = isolationAvailable
        let exportItem = menu.addItem(withTitle: "Export Profile Settings…", action: #selector(exportCurrentProfileAction(_:)), keyEquivalent: "")
        exportItem.target = self
        let importItem = menu.addItem(withTitle: "Import Profile Settings…", action: #selector(importProfileAction(_:)), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = isolationAvailable
        let renameItem = menu.addItem(withTitle: "Rename Current Profile…", action: #selector(renameCurrentProfileAction(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = isolationAvailable || currentID == defaultProfileID
        let deleteItem = menu.addItem(withTitle: "Delete Current Profile…", action: #selector(deleteCurrentProfileAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = canDeleteProfile(currentID)
        if currentID == defaultProfileID {
            deleteItem.toolTip = "Deleting the built-in profile clears the default WebView data store and immediately creates a new built-in profile."
        }

        menu.addItem(NSMenuItem.separator())
        let inspectOrphansItem = menu.addItem(
            withTitle: "Check Leftover Profile Data…",
            action: #selector(inspectOrphanedProfileDataStores(_:)),
            keyEquivalent: ""
        )
        inspectOrphansItem.target = self
        inspectOrphansItem.isEnabled = isolationAvailable

        if !isolationAvailable {
            menu.addItem(NSMenuItem.separator())
            let hint = menu.addItem(withTitle: "Profile isolation requires macOS 14 or later", action: nil, keyEquivalent: "")
            hint.isEnabled = false
        }
    }

    private var isProfileIsolationAvailable: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private func canUseProfile(_ id: String) -> Bool {
        isProfileIsolationAvailable || id == defaultProfileID
    }

    private func canDeleteProfile(_ id: String) -> Bool {
        id == defaultProfileID || isProfileIsolationAvailable
    }

    private func profileMenuTitle(for profile: WebProfile, currentID: String, startupID: String) -> String {
        var badges: [String] = []
        if profile.id == startupID {
            badges.append("Startup Default")
        }
        if profile.id == defaultProfileID {
            badges.append("Built-In")
        }
        let suffix = badges.isEmpty ? "" : " (\(badges.joined(separator: ", ")))"
        return "\(profile.id == currentID ? "●" : " ") \(profile.name)\(suffix)"
    }

    private func rebuildPrivacyMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentID = ProfileStore.currentProfileID()

        let webRTCItem = menu.addItem(withTitle: "Enable WebRTC Protection", action: #selector(toggleWebRTCProtection(_:)), keyEquivalent: "")
        webRTCItem.target = self
        webRTCProtectionItem = webRTCItem
        updateWebRTCProtectionMenuItem()

        let thirdPartyItem = menu.addItem(withTitle: "Open Third-Party Links in App", action: #selector(toggleThirdPartyLinksInApp(_:)), keyEquivalent: "")
        thirdPartyItem.target = self
        thirdPartyItem.state = PrivacySettings.keepThirdPartyLinksInApp() ? .on : .off

        menu.addItem(NSMenuItem.separator())
        let fingerprintItem = menu.addItem(withTitle: "Fingerprint Preset", action: nil, keyEquivalent: "")
        let fingerprintMenu = NSMenu(title: "Fingerprint Preset")
        rebuildFingerprintMenu(fingerprintMenu, profileID: currentID)
        fingerprintItem.submenu = fingerprintMenu

        let enhancedItem = menu.addItem(withTitle: "Enhanced Privacy (Current Profile)", action: #selector(toggleEnhancedPrivacy(_:)), keyEquivalent: "")
        enhancedItem.target = self
        enhancedPrivacyItem = enhancedItem
        updateEnhancedPrivacyMenuItem()

        menu.addItem(NSMenuItem.separator())
        let privacyStatusItem = menu.addItem(withTitle: "Privacy Status...", action: #selector(showPrivacyStatus(_:)), keyEquivalent: "")
        privacyStatusItem.target = self
        let fingerprintTestItem = menu.addItem(withTitle: "Open Fingerprint Test Page", action: #selector(openFingerprintTestPage(_:)), keyEquivalent: "")
        fingerprintTestItem.target = self
    }

    private func rebuildFingerprintMenu(_ menu: NSMenu, profileID: String) {
        menu.removeAllItems()
        let currentFingerprint = ProfileStore.fingerprint(for: profileID)
        let currentPresetID = currentFingerprint?.presetID ?? FingerprintCatalog.offPresetID

        let offTitle = currentPresetID == FingerprintCatalog.offPresetID
            ? "● Default Safari (No Obfuscation)"
            : "  Default Safari (No Obfuscation)"
        let offItem = menu.addItem(withTitle: offTitle, action: #selector(selectFingerprintPreset(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = FingerprintCatalog.offPresetID

        for preset in FingerprintCatalog.presets {
            let isSelected = preset.presetID == currentPresetID
            let item = menu.addItem(withTitle: "\(isSelected ? "●" : " ") \(preset.displayName)", action: #selector(selectFingerprintPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.presetID
        }

        if let currentFingerprint, currentFingerprint.presetID.hasPrefix("random-") {
            menu.addItem(NSMenuItem.separator())
            let randomItem = menu.addItem(withTitle: "● \(currentFingerprint.displayName)", action: nil, keyEquivalent: "")
            randomItem.isEnabled = false
        }

        menu.addItem(NSMenuItem.separator())
        let randomizeItem = menu.addItem(withTitle: "Randomize Again (Current Profile)", action: #selector(randomizeCurrentFingerprint(_:)), keyEquivalent: "")
        randomizeItem.target = self
        menu.addItem(NSMenuItem.separator())
        let aboutItem = menu.addItem(withTitle: "About Fingerprint Obfuscation…", action: #selector(showFingerprintAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
    }

    /// Refresh the optional fingerprint's exit timezone for the next WebView. Never rebuild a live
    /// session after launch: changing browser characteristics mid-session invalidates challenge state
    /// and turns an otherwise background lookup into a visible second page load.
    private func refreshExitTimezoneCache() {
        GeoIPResolver.refresh()
    }

    private func rebuildMainController(initialURL: URL? = nil) {
        // Profile switch keeps full WebView rebuild: each profile owns an isolated
        // WKWebsiteDataStore, so reusing one WebView across profiles would leak cookies
        // across spaces. Callers (switchToProfile) flush draft/page state via
        // capturePageState before reaching here.
        let oldController = mainController
        oldController?.persistMainWindowFrame()
        mainController = nil
        if let oldController, !oldController.isDisposing {
            oldController.dispose()
        }

        let profile = ProfileStore.currentProfile()
        let controller = BrowserWindowController(
            initialURL: initialURL ?? ProfileStore.homepageURL(for: profile.id),
            title: mainWindowTitle(for: profile),
            isPopup: false,
            persistent: true,
            profileID: profile.id
        )
        mainController = controller
        controller.show()
        updateWebRTCProtectionMenuItem()
        updateEnhancedPrivacyMenuItem()
        refreshNativeUtilityWindows()
    }

    func recoverBlankContent(in controller: BrowserWindowController) {
        guard !profileMutationInProgress, ProfileStore.pendingDataMutation == nil else {
            return
        }
        if controller === mainController {
            rebuildMainController(initialURL: controller.currentURL())
        } else {
            controller.hardReload(ignoringCache: true)
        }
    }

    private func mainWindowTitle(for profile: WebProfile) -> String {
        ProfileWindowTitle.format(
            profileName: profile.name,
            isDefault: profile.id == defaultProfileID,
            mode: WindowTitleSettings.mode()
        )
    }

    private func ensureIsolationAvailable() -> Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Cannot Create Profile"
        alert.informativeText = "Multiple isolated profiles require macOS 14 or later. This system supports only the built-in profile and private windows."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    private func ensureProfileMetadataWritable() -> Bool {
        guard !profileSwitchInProgress else { return false }
        guard !profileMutationInProgress else {
            return false
        }
        guard !ProfileStore.metadataRecoveryRequired else {
            presentError("Cannot read profile settings. The original configuration was preserved. Restore valid settings before changing profiles.")
            return false
        }
        guard ProfileStore.pendingDataMutation == nil else {
            presentError("The previous profile data operation is still recovering. Writes are paused; wait for recovery to finish.")
            return false
        }
        return true
    }

    private func updateWebRTCProtectionMenuItem() {
        webRTCProtectionItem?.title = PrivacySettings.isWebRTCProtectionEnabled()
            ? "Disable WebRTC Protection"
            : "Enable WebRTC Protection"
        webRTCProtectionItem?.state = .off
    }

    private func updateEnhancedPrivacyMenuItem() {
        let currentID = ProfileStore.currentProfileID()
        enhancedPrivacyItem?.title = "Enhanced Privacy (Current Profile)"
        enhancedPrivacyItem?.state = ProfileStore.isEnhancedPrivacyEnabled(for: currentID) ? .on : .off
    }

    private func createProfileFromCurrent(named name: String, copyCookies: Bool) {
        guard ensureProfileMetadataWritable() else { return }
        profileMutationInProgress = true
        let sourceID = ProfileStore.currentProfileID()
        let newProfile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
        var profiles = ProfileStore.loadProfiles()
        profiles.append(newProfile)
        ProfileStore.save(profiles)

        guard ProfileStore.loadProfiles().contains(where: { $0.id == newProfile.id }) else {
            profileMutationInProgress = false
            presentError("Could not clone profile: settings could not be saved.")
            return
        }

        if let homepage = ProfileStore.homepageString(for: sourceID),
           let url = URL(string: homepage) {
            ProfileStore.setHomepage(url, for: newProfile.id)
        }
        ProfileStore.disableFingerprint(for: newProfile.id)
        ProfileStore.setEnhancedPrivacyEnabled(ProfileStore.isEnhancedPrivacyEnabled(for: sourceID), for: newProfile.id)

        let switchToNewProfile = { [weak self] () -> Bool in
            guard let self else { return false }
            guard !ProfileStore.metadataRecoveryRequired,
                  ProfileStore.loadProfiles().contains(where: { $0.id == newProfile.id }) else {
                self.profileMutationInProgress = false
                self.applyCurrentCookiePreferenceAfterMutation()
                self.presentError("Profile cloning did not finish: the target profile no longer exists or settings need recovery.")
                return false
            }
            ProfileStore.setCurrentProfileID(newProfile.id)
            self.profileMutationInProgress = false
            self.applyCurrentCookiePreferenceAfterMutation()
            self.updateWebRTCProtectionMenuItem()
            self.rebuildMainController()
            return true
        }

        guard copyCookies, let controller = mainController else {
            _ = switchToNewProfile()
            return
        }

        controller.copyCookies(toProfileID: newProfile.id) { [weak self] count, skippedCount, essentialSkipped in
            if switchToNewProfile() {
                let skippedText = skippedCount > 0 ? ", skipped \(skippedCount) cookies to avoid oversized request headers" : ""
                if essentialSkipped {
                    self?.presentAlert(
                        "Created profile “\(name)” and copied \(count) cookies\(skippedText), but essential login cookies exceeded the size or request header limit. The login session was not fully copied.",
                        style: .warning
                    )
                } else {
                    self?.presentInfo("Cloned profile “\(name)” and copied \(count) cookies\(skippedText).")
                }
            }
        }
    }

    private func exportCurrentProfile(to url: URL) {
        let profile = ProfileStore.currentProfile()
        let document = ProfileExportDocument(
            schemaVersion: 1,
            exportedAt: Date(),
            sourceProfileID: profile.id,
            name: profile.name,
            homepage: ProfileStore.homepageString(for: profile.id),
            fingerprint: ProfileStore.fingerprint(for: profile.id),
            fingerprintDisabled: ProfileStore.isFingerprintDisabled(for: profile.id),
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id)
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try BrowserDataBoundary.writeSensitiveData(data, to: url)
            presentInfo("Exported profile settings to \(url.lastPathComponent).")
        } catch {
            presentError("Profile export failed: \(error.localizedDescription)")
        }
    }

    private func importProfile(from url: URL) {
        guard ensureProfileMetadataWritable() else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > maximumProfileImportBytes {
                throw NSError(
                    domain: "ChatGPTSwiftWeb.ProfileImport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Profile file is too large"]
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ProfileExportDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                presentError("Unsupported profile JSON version.")
                return
            }
            guard Self.isValidImportedProfileDocument(document) else {
                presentError("Profile JSON contains invalid or out-of-range settings.")
                return
            }

            let name = uniqueProfileName(document.name.isEmpty ? "Imported Profile" : document.name)
            let profile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
            var profiles = ProfileStore.loadProfiles()
            profiles.append(profile)
            ProfileStore.save(profiles)

            if let homepage = document.homepage,
               let url = NavigationRules.validatedExternalURL(homepage) {
                ProfileStore.setHomepage(url, for: profile.id)
            }
            if let fingerprint = document.fingerprint, document.fingerprintDisabled != true {
                ProfileStore.setFingerprint(fingerprint, for: profile.id)
            } else {
                ProfileStore.disableFingerprint(for: profile.id)
            }
            ProfileStore.setEnhancedPrivacyEnabled(document.enhancedPrivacyEnabled, for: profile.id)
            ProfileStore.setCurrentProfileID(profile.id)
            updateWebRTCProtectionMenuItem()
            rebuildMainController()
            presentInfo("Imported profile settings for “\(name)”.")
        } catch {
            presentError("Profile import failed: \(error.localizedDescription)")
        }
    }

    private static func isValidImportedProfileDocument(_ document: ProfileExportDocument) -> Bool {
        func validText(_ value: String, maximumLength: Int) -> Bool {
            !value.isEmpty
                && value.count <= maximumLength
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

        guard validText(document.name, maximumLength: 256),
              document.sourceProfileID == defaultProfileID || UUID(uuidString: document.sourceProfileID) != nil else {
            return false
        }
        if let homepage = document.homepage {
            guard NavigationRules.validatedExternalURL(homepage) != nil else {
                return false
            }
        }
        if let fingerprint = document.fingerprint, !fingerprint.isValidForImport() {
            return false
        }
        return true
    }

    private func uniqueProfileName(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTrimmed = String(trimmed.prefix(256))
        let base = safeTrimmed.isEmpty
            || safeTrimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            ? "New Profile"
            : safeTrimmed
        let profiles = ProfileStore.loadProfiles()
        if !Self.profileNameExists(base, in: profiles, excluding: nil) {
            return base
        }

        var index = 2
        while true {
            let candidate = "\(base) \(index)"
            if !Self.profileNameExists(candidate, in: profiles, excluding: nil) {
                return candidate
            }
            index += 1
        }
    }

    private func presentError(_ text: String) {
        presentAlert(text, style: .warning)
    }

    private func presentInfo(_ text: String) {
        presentAlert(text, style: .informational)
    }

    private func presentAlert(_ text: String, style: NSAlert.Style) {
        let safeText = DiagnosticRedactor.text(text)
        (BrowserWindowController.keyWindowController() ?? mainController)?.showToast(
            safeText, actionTitle: style == .warning ? "Copy Diagnostics" : nil,
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(safeText, forType: .string)
            }, duration: style == .warning ? 12 : 6)
    }

    private func promptForURL(title: String, message: String, initial: String, completion: @escaping (URL?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        textField.stringValue = initial
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !trimmed.isEmpty else {
            completion(nil)
            return
        }
        guard let url = Self.validatedExternalURL(trimmed) else {
            let warn = NSAlert()
            warn.messageText = "Invalid URL"
            warn.informativeText = "Enter a complete https:// URL, such as https://example.com. Only HTTPS is supported; unencrypted HTTP is blocked."
            warn.alertStyle = .warning
            warn.addButton(withTitle: "OK")
            warn.runModal()
            completion(nil)
            return
        }
        completion(url)
    }

    private static func validatedExternalURL(_ raw: String) -> URL? {
        NavigationRules.validatedExternalURL(raw)
    }

    private func promptForName(title: String, initial: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = initial
        textField.placeholderString = "For example: Work / Personal"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn,
           !trimmed.isEmpty,
           trimmed.count <= 256,
           !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            completion(trimmed)
        } else {
            completion(nil)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
