import CryptoKit
import Foundation
import WebKit

/// Keeps Cloudflare challenge pages inside the normal WebKit session and exposes only
/// non-sensitive health signals. It deliberately does not solve or bypass challenges.
extension BrowserWindowController {
    func cloudflareDiagnosticsSummary() -> String {
        let state = isCloudflareChallengeActive ? "Challenge in progress" : "Idle"
        let network = NetworkStatusMonitor.shared.availability.title + " · " + NetworkStatusMonitor.shared.interfaceDescription
        let eventTime = cloudflareLastEventAt.map { date in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        } ?? "None"
        return [
            "Status: " + state,
            "Challenges: " + String(cloudflareChallengeCount) + " times, completed " + String(cloudflareChallengeResolvedCount) + " times, loops " + String(cloudflareChallengeLoopCount) + " times",
            "Latest event: HTTP " + cloudflareLastHTTPStatus + ", Ray ID " + cloudflareLastRayID + ", " + eventTime,
            "Challenge Cookies: " + cloudflareChallengeCookieStatus,
            "Egress Sample: " + cloudflareEgressStatus + " (sampled " + String(cloudflareEgressSampleCount) + " times)",
            "Network: " + network,
        ].joined(separator: "\n")
    }

    func recordCloudflareChallengeResponse(_ response: HTTPURLResponse) {
        cloudflareLastHTTPStatus = String(response.statusCode)
        cloudflareLastEventAt = Date()
        if let rawRayID = response.value(forHTTPHeaderField: "cf-ray") {
            let safeRayID = rawRayID.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
            }
            cloudflareLastRayID = String(String.UnicodeScalarView(safeRayID).prefix(128))
        } else {
            cloudflareLastRayID = "Missing"
        }
        sampleCloudflareEgressIfNeeded()
    }

    static func isCloudflareChallengeNavigationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "challenges.cloudflare.com" || host.hasSuffix(".challenges.cloudflare.com") {
            return true
        }
        let path = url.path.lowercased()
        return path.hasPrefix("/cdn-cgi/challenge-platform/")
            || path.hasPrefix("/cdn-cgi/challenge/")
    }

    func beginCloudflareChallenge(reason: String) {
        guard !isDisposing else { return }
        if isCloudflareChallengeActive {
            if cloudflareChallengeLastReason != reason {
                cloudflareChallengeLoopCount += 1
            }
        } else {
            cloudflareChallengeCount += 1
            cloudflareChallengeStartedAt = Date()
        }
        isCloudflareChallengeActive = true
        lastFailureStatus = nil
        hasFailedNavigation = false
        cloudflareChallengeLastReason = reason
        refreshCloudflareChallengeCookieStatus()
        sampleCloudflareEgressIfNeeded()
        scheduleCloudflareChallengeWatchdog()
        updateNativeChromeStatus()
    }

    func completeCloudflareChallenge() {
        guard isCloudflareChallengeActive else { return }
        isCloudflareChallengeActive = false
        cloudflareChallengeResolvedCount += 1
        cloudflareChallengeStartedAt = nil
        cloudflareChallengeLastReason = "Completed"
        cancelCloudflareChallengeWatchdog()
        refreshCloudflareChallengeCookieStatus()
        updateNativeChromeStatus()
        completeDataVerificationIfReady()
    }

    func failCloudflareChallenge(reason: String) {
        guard isCloudflareChallengeActive else { return }
        isCloudflareChallengeActive = false
        cloudflareChallengeStartedAt = nil
        cloudflareChallengeLastReason = reason
        cancelCloudflareChallengeWatchdog()
        refreshCloudflareChallengeCookieStatus()
        updateNativeChromeStatus()
    }

    func noteCloudflareNetworkChange() {
        guard isCloudflareChallengeActive else { return }
        cloudflareChallengeLoopCount += 1
        cloudflareChallengeLastReason = "Network interface changed; keep the current network unchanged"
        refreshCloudflareChallengeCookieStatus()
        scheduleCloudflareChallengeWatchdog()
        updateNativeChromeStatus()
    }

    func invalidateCloudflareChallengeTracking() {
        cloudflareChallengeWatchdogGeneration &+= 1
        cloudflareChallengeWatchdogWorkItem?.cancel()
        cloudflareChallengeWatchdogWorkItem = nil
        isCloudflareChallengeActive = false
        cloudflareChallengeStartedAt = nil
    }

    private func scheduleCloudflareChallengeWatchdog() {
        cloudflareChallengeWatchdogGeneration &+= 1
        let expected = cloudflareChallengeWatchdogGeneration
        cloudflareChallengeWatchdogWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isDisposing,
                  self.cloudflareChallengeWatchdogGeneration == expected,
                  self.isCloudflareChallengeActive else { return }
            self.cloudflareChallengeLastReason = "Waiting more than 12 seconds; keep the current network and window unchanged"
            self.refreshCloudflareChallengeCookieStatus()
            self.updateNativeChromeStatus()
        }
        cloudflareChallengeWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func cancelCloudflareChallengeWatchdog() {
        cloudflareChallengeWatchdogGeneration &+= 1
        cloudflareChallengeWatchdogWorkItem?.cancel()
        cloudflareChallengeWatchdogWorkItem = nil
    }

    private func refreshCloudflareChallengeCookieStatus() {
        guard !isDisposing else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let relevantNames = Set(cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                let isOpenAIHost = domain == "chatgpt.com"
                    || domain.hasSuffix(".chatgpt.com")
                    || domain == "openai.com"
                    || domain.hasSuffix(".openai.com")
                return isOpenAIHost && (cookie.name == "cf_clearance" || cookie.name == "__cf_bm")
            }.map(\.name))
            let clearance = relevantNames.contains("cf_clearance") ? "clearance=present" : "clearance=missing"
            let bot = relevantNames.contains("__cf_bm") ? "bot=present" : "bot=missing"
            DispatchQueue.main.async {
                guard let self, !self.isDisposing else { return }
                self.cloudflareChallengeCookieStatus = "\(clearance); \(bot)"
                self.updateNativeChromeStatus()
            }
        }
    }

    private func sampleCloudflareEgressIfNeeded() {
        guard !cloudflareEgressSampleInFlight,
              cloudflareEgressSampledChallengeCount != cloudflareChallengeCount else { return }
        cloudflareEgressSampledChallengeCount = cloudflareChallengeCount
        cloudflareEgressSampleInFlight = true
        cloudflareEgressSampleCount += 1

        guard let url = URL(string: "https://cloudflare.com/cdn-cgi/trace") else {
            cloudflareEgressSampleInFlight = false
            cloudflareEgressStatus = "Sample URL unavailable"
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { [weak self] data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let self,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data,
                  let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    guard let self, !self.isDisposing else { return }
                    self.cloudflareEgressSampleInFlight = false
                    self.cloudflareEgressStatus = "Sampling failed (cookies are not read)"
                    self.updateNativeChromeStatus()
                }
                return
            }

            var values: [String: String] = [:]
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            guard let ip = values["ip"], !ip.isEmpty else {
                DispatchQueue.main.async {
                    guard !self.isDisposing else { return }
                    self.cloudflareEgressSampleInFlight = false
                    self.cloudflareEgressStatus = "Sample has no egress information"
                    self.updateNativeChromeStatus()
                }
                return
            }

            let fingerprint = SHA256.hash(data: Data(ip.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            let location = [values["loc"], values["colo"]].compactMap { $0 }.joined(separator: "/")
            DispatchQueue.main.async {
                guard !self.isDisposing else { return }
                let changed: String
                if let previous = self.cloudflareLastEgressFingerprint {
                    changed = previous == fingerprint ? "Egress unchanged" : "Egress changed"
                } else {
                    changed = "Egress baseline established"
                }
                self.cloudflareLastEgressFingerprint = fingerprint
                self.cloudflareEgressSampleInFlight = false
                self.cloudflareEgressStatus = changed + "; location " + (location.isEmpty ? "Unknown" : location)
                self.updateNativeChromeStatus()
            }
        }.resume()
    }
}
