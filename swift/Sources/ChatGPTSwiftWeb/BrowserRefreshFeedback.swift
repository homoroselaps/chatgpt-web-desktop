import AppKit
import ChatGPTSwiftWebCore
import Foundation
import WebKit

enum RefreshButtonState: String {
    case idle, loading, completed, failed
}

/// Navigation identity protects both terminal callbacks and delayed feedback from an older load.
@MainActor
final class BrowserRefreshFeedback {
    private(set) var state: RefreshButtonState = .idle
    private(set) var isManualRefresh = false
    private(set) var isVerifying = false
    private(set) var generation = 0
    private var navigation: WKNavigation?
    private var awaitingNavigation = false
    private var resetWork: DispatchWorkItem?
    private var verificationTimeout: DispatchWorkItem?
    var onChange: (() -> Void)?

    func beginRefresh() -> Bool {
        guard !(isManualRefresh && state == .loading) else { return false }
        invalidate()
        isManualRefresh = true
        awaitingNavigation = true
        transition(.loading)
        return true
    }

    func trackRequestedNavigation(_ next: WKNavigation?) {
        // A privacy rewrite can replace the WebKit navigation without replacing
        // the user's refresh. Invalidate probes tied to the replaced navigation.
        if let navigation, navigation !== next {
            generation += 1
            verificationTimeout?.cancel()
            verificationTimeout = nil
            isVerifying = false
        }
        navigation = next
        awaitingNavigation = false
        if next == nil { transition(.failed) }
    }

    @discardableResult
    func navigationStarted(_ next: WKNavigation?) -> Bool {
        // A previous navigation can deliver a late provisional-start callback after
        // a manual refresh has already registered its new WKNavigation. Ignore that
        // callback instead of replacing the current request and its feedback.
        if isManualRefresh, state == .loading, !awaitingNavigation,
           let navigation, navigation !== next {
            return false
        }
        if !awaitingNavigation && (!accepts(next) || navigation == nil) {
            invalidate()
            isManualRefresh = false
        }
        navigation = next
        awaitingNavigation = false
        transition(.loading)
        return true
    }

    func accepts(_ candidate: WKNavigation?) -> Bool {
        if awaitingNavigation { return false }
        guard let navigation else { return candidate == nil }
        return navigation === candidate
    }

    /// A successful main-frame navigation still needs to rule out blank/challenge content.
    @discardableResult
    func navigationFinished(_ candidate: WKNavigation?) -> Bool {
        guard accepts(candidate), state == .loading, !isVerifying else { return false }
        guard isManualRefresh else { transition(.idle); return false }
        isVerifying = true
        let expected = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, self.state == .loading else { return }
            self.transition(.failed)
        }
        verificationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        onChange?()
        return true
    }

    func verified(_ candidate: WKNavigation?, generation expected: Int, success: Bool) {
        guard generation == expected, accepts(candidate), state == .loading, isVerifying else { return }
        transition(success ? .completed : .failed)
        guard success else { return }
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, self.state == .completed else { return }
            self.transition(.idle)
        }
        resetWork = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: reset)
    }

    func navigationFailed(_ candidate: WKNavigation?) {
        guard accepts(candidate), state == .loading else { return }
        transition(.failed)
    }

    func dataLoadFailed() {
        guard isManualRefresh else { return }
        transition(.failed)
    }

    func navigationCancelled(_ candidate: WKNavigation?) {
        guard accepts(candidate), state == .loading else { return }
        transition(.idle)
    }

    func navigationBecameDownload() {
        invalidate()
        transition(.idle)
    }

    func processTerminated() {
        invalidate()
        transition(.failed)
    }

    func invalidate() {
        generation += 1
        resetWork?.cancel()
        verificationTimeout?.cancel()
        resetWork = nil
        verificationTimeout = nil
        navigation = nil
        awaitingNavigation = false
        isVerifying = false
        isManualRefresh = false
    }

    private func transition(_ next: RefreshButtonState) {
        if next != .loading {
            verificationTimeout?.cancel()
            verificationTimeout = nil
            isVerifying = false
        }
        state = next
        onChange?()
    }
}

extension BrowserWindowController {
    func updateRefreshButtonAppearance() {
        let activeController = dataVerificationWindow ?? self
        let feedback = activeController.refreshFeedback
        let loading = feedback.state == .loading
        let verb = feedback.isManualRefresh ? "Refresh" : "Load"
        let label: String
        let symbol: String?
        let tint: NSColor?
        switch feedback.state {
        case .idle:
            if dataVerificationWindow != nil {
                label = "Reload Verification Page"
            } else if dataLoadState.requiresVerification {
                label = "Complete Security Verification and Retry"
            } else if dataLoadState.hasFailure {
                label = "Retry Loading \(dataLoadState.summary)"
            } else if modelLoadFailureActive {
                label = "Retry Loading Models"
            } else {
                label = isShowingBlankContent ? "Recover Blank Page" : "Reload"
            }
            symbol = "arrow.clockwise"
            tint = modelLoadFailureActive || dataLoadState.hasFailure ? .systemOrange : nil
        case .loading:
            if activeController.isCloudflareChallengeActive {
                label = "Verifying Page"
            } else if feedback.isVerifying {
                label = "Checking Page Content"
            } else {
                let percent = max(1, min(99, Int(activeController.webView.estimatedProgress * 100)))
                label = "\(verb) Page (About \(percent)%)"
            }
            symbol = nil
            tint = nil
        case .completed:
            label = "Refresh Complete"
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
        case .failed:
            label = dataVerificationWindow != nil ? "Reload Verification Page"
                : (dataLoadState.requiresVerification ? "Complete Security Verification and Retry" : "\(verb) Incomplete. Click to Retry")
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        }
        navigationReloadButton?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        navigationReloadButton?.contentTintColor = tint
        navigationReloadButton?.isEnabled = !loading
        navigationReloadButton?.toolTip = label
        navigationReloadButton?.setAccessibilityLabel(label)
        toolbarItems[.chatGPTReload]?.toolTip = label
        toolbarItems[.chatGPTReload]?.isEnabled = !loading
        navigationReloadSpinner?.isHidden = !loading
        if loading { navigationReloadSpinner?.startAnimation(nil) }
        else { navigationReloadSpinner?.stopAnimation(nil) }
        if let entry = toolbarItems[.chatGPTNavigation]?.menuFormRepresentation?.submenu?.items.last {
            entry.title = label
            entry.isEnabled = !loading
        }
    }

    func verifyRefreshedPage(navigation: WKNavigation, generation: Int? = nil, attempt: Int = 0) {
        let expected = generation ?? refreshFeedback.generation
        guard !isDisposing, refreshFeedback.generation == expected,
              refreshFeedback.state == .loading, refreshFeedback.isVerifying,
              refreshFeedback.accepts(navigation) else { return }
        webView.evaluateJavaScript(Self.renderedContentProbeScript) { [weak self] value, error in
            guard let self, !self.isDisposing, self.refreshFeedback.generation == expected,
                  self.refreshFeedback.accepts(navigation), self.refreshFeedback.state == .loading,
                  self.refreshFeedback.isVerifying else { return }
            guard error == nil, let report = value as? [String: Any] else {
                self.refreshFeedback.verified(navigation, generation: expected, success: false)
                return
            }
            let challenge = report["cloudflareChallenge"] as? Bool == true
            let blank = report["blank"] as? Bool != false
            let ready = report["readyState"] as? String == "complete"
            if challenge {
                self.beginCloudflareChallenge(reason: "Content probe detected a challenge after refresh")
            } else if self.isCloudflareChallengeActive,
                      ready,
                      let host = self.webView.url?.host?.lowercased(),
                      NavigationRules.isChatGPTHost(host) {
                self.completeCloudflareChallenge()
            }
            if (!ready || challenge || blank) && attempt < 10 {
                self.updateNativeChromeStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.verifyRefreshedPage(navigation: navigation, generation: expected, attempt: attempt + 1)
                }
            } else {
                self.lastRenderProbeWasBlank = blank && !challenge
                self.refreshFeedback.verified(navigation, generation: expected,
                                              success: ready && !challenge && !blank && !self.dataLoadState.hasFailure
                                                && report["dataLoadFailure"] as? Bool != true)
                self.updateNativeChromeStatus()
            }
        }
    }
}
