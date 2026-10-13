import AppKit
import ChatGPTSwiftWebCore

extension BrowserWindowController {
    func showToast(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, duration: TimeInterval = 5) {
        guard !isDisposing else { return }
        toastView.show(message: message, actionTitle: actionTitle, action: action, duration: duration)
    }

    @objc func showDownloads(_ sender: Any?) {
        if downloadWindowController == nil {
            downloadWindowController = DownloadCenterWindowController(center: .shared, profileID: downloadScope)
            downloadWindowController?.window?.center()
        }
        downloadWindowController?.render()
        downloadWindowController?.showWindow(sender)
        downloadWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    func observeUtilityState() {
        utilityObservers.append(NotificationCenter.default.addObserver(forName: .chatGPTSwiftDownloadCenterDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDownloadButton() }
        })
        utilityObservers.append(NotificationCenter.default.addObserver(forName: .chatGPTSwiftNetworkDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.networkChanged(
                    restored: note.userInfo?["restored"] as? Bool == true,
                    interfaceChanged: note.userInfo?["interfaceChanged"] as? Bool == true
                )
            }
        })
        updateDownloadButton()
        updateProfileButton()
    }

    func stopUtilityObservers() {
        utilityObservers.forEach(NotificationCenter.default.removeObserver)
        utilityObservers.removeAll()
        downloadWindowController?.close()
        downloadWindowController = nil
    }

    func updateDownloadButton() {
        let records = DownloadCenter.shared.records.filter { $0.profileID == downloadScope }
        let active = records.filter { $0.state == .downloading }
        let fractions = active.compactMap(\.progress)
        let percent = fractions.isEmpty ? "" : " · \(Int(fractions.reduce(0, +) / Double(fractions.count) * 100))%"
        // Compact: icon-only when idle-empty, short count otherwise. Never a persistent
        // long "下载 0" title that squeezes the toolbar at narrow widths.
        let title: String
        let accessibility: String
        let toolTip: String
        if !active.isEmpty {
            title = active.count > 99 ? "99+" : "\(active.count)"
            accessibility = "Download Center, \(active.count) active downloads\(percent)"
            toolTip = "Open Download Center (\(active.count) active downloads\(percent))"
        } else if !records.isEmpty {
            title = "\(records.count)"
            accessibility = "Download Center, \(records.count) records"
            toolTip = "Open Download Center (\(records.count) records)"
        } else {
            title = ""
            accessibility = "Download Center, no records"
            toolTip = "Open Download Center"
        }
        downloadButton?.title = title
        downloadButton?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        downloadButton?.setAccessibilityLabel(accessibility)
        downloadButton?.toolTip = toolTip
        toolbarItems[.chatGPTDownloads]?.label = "Download Center"
        toolbarItems[.chatGPTDownloads]?.toolTip = toolTip
        toolbarItems[.chatGPTDownloads]?.menuFormRepresentation?.title = toolTip
    }

    func updateProfileButton() {
        let currentID = profileID ?? defaultProfileID
        let name = persistent ? (ProfileStore.loadProfiles().first(where: { $0.id == currentID })?.name
            ?? (currentID == defaultProfileID ? "Default" : "Profiles")) : "Private"
        let formatted = ProfileWindowTitle.format(profileName: name, isDefault: persistent && currentID == defaultProfileID,
                                                 mode: WindowTitleSettings.mode())
        let prefix = "ChatGPT Swift — "
        let displayName = formatted.hasPrefix(prefix) ? String(formatted.dropFirst(prefix.count)) : ""
        profileButton?.title = displayName.isEmpty ? "▾" : displayName + "  ▾"
        profileButton?.imagePosition = .imageLeading
        profileButton?.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profiles")
        profileButton?.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: profileButton?.font?.pointSize ?? 13, weight: .regular)
        let toolTip = "Profile: \(name) — Click to Switch"
        let accessibility = "Profile, currently \(name), click to switch profiles"
        profileButton?.toolTip = toolTip
        profileButton?.setAccessibilityLabel(accessibility)
        toolbarItems[.chatGPTProfile]?.label = "Profiles"
        toolbarItems[.chatGPTProfile]?.paletteLabel = "Profiles"
        toolbarItems[.chatGPTProfile]?.toolTip = toolTip
        toolbarItems[.chatGPTProfile]?.menuFormRepresentation?.title = toolTip
    }

    func networkChanged(restored: Bool, interfaceChanged: Bool = false) {
        guard !isDisposing else { return }
        if interfaceChanged, isCloudflareChallengeActive {
            noteCloudflareNetworkChange()
        }
        if NetworkStatusMonitor.shared.availability == .offline {
            networkRetryUsed = false
            if hasFailedNavigation { networkRetryPending = true }
        }
        if restored, networkRetryPending, !networkRetryUsed, hasFailedNavigation,
           !isAssistantResponseInProgress, ProfileStore.pendingDataMutation == nil {
            networkRetryUsed = true
            networkRetryPending = false
            showToast("Network restored. Reloading")
            hardReload()
        }
        updateNativeChromeStatus()
    }

    @objc func showProfileSwitcher(_ sender: Any?) {
        guard persistent else { showToast("Private windows use a separate temporary profile"); return }
        let menu = NSMenu(title: "Profiles")
        let currentID = profileID ?? defaultProfileID
        let startupID = ProfileStore.startupProfileID()
        for profile in ProfileStore.loadProfiles() {
            let badges = [profile.id == currentID ? "Current" : nil, profile.id == startupID ? "Startup Default" : nil].compactMap { $0 }
            let item = NSMenuItem(title: profile.name + (badges.isEmpty ? "" : " (\(badges.joined(separator: ", ")))"),
                                 action: #selector(AppDelegate.switchToProfile(_:)), keyEquivalent: "")
            item.target = NSApp.delegate
            item.representedObject = profile.id
            item.state = profile.id == currentID ? .on : .off
            item.image = Self.profileColorImage(id: profile.id)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage profiles in the File menu", action: nil, keyEquivalent: "")
        manage.isEnabled = false
        menu.addItem(manage)
        if let button = profileButton, button.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            // Overflow items have no visible button to anchor to.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func profileColorImage(id: String) -> NSImage {
        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        let index = id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            colors[index].setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}
