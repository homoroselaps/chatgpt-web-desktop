import Foundation
import Network

enum NetworkAvailability: Equatable {
    case unknown
    case online
    case constrained
    case offline

    var title: String {
        switch self {
        case .unknown: return "Network status unknown"
        case .online: return "Network connected"
        case .constrained: return "Network constrained"
        case .offline: return "Network disconnected"
        }
    }
}

@MainActor
final class NetworkStatusMonitor {
    static let shared = NetworkStatusMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ChatGPTSwiftWeb.NetworkStatus", qos: .utility)
    private(set) var availability: NetworkAvailability = .unknown
    private(set) var interfaceDescription = "Not checked"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next: NetworkAvailability
            if path.status != .satisfied {
                next = .offline
            } else if path.isConstrained {
                next = .constrained
            } else {
                next = .online
            }
            let interface = path.availableInterfaces.map { $0.type == .wifi ? "Wi-Fi" : $0.type == .wiredEthernet ? "Ethernet" : $0.type == .cellular ? "Cellular" : "Other" }.joined(separator: ", ")
            DispatchQueue.main.async {
                guard let self else { return }
                let old = self.availability
                let oldInterface = self.interfaceDescription
                self.availability = next
                self.interfaceDescription = interface.isEmpty ? "No available interfaces" : interface
                NotificationCenter.default.post(name: .chatGPTSwiftNetworkDidChange, object: self,
                    userInfo: [
                        "restored": old == .offline && next != .offline,
                        "interfaceChanged": oldInterface != self.interfaceDescription,
                    ])
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }
}

extension Notification.Name {
    static let chatGPTSwiftNetworkDidChange = Notification.Name("ChatGPTSwift.NetworkDidChange")
}

enum NavigationFailure {
    static func description(for error: Error, offline: Bool) -> String {
        if offline { return "Network disconnected. Will retry once when connected" }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return "Page failed to load. Try again" }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Could not resolve the server name. Check DNS or your proxy"
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to the server. Check your network or proxy"
        case NSURLErrorTimedOut:
            return "Connection timed out. Try again"
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return "Connection interrupted. Will retry once when connected"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "Secure connection failed. Check the system time or network proxy"
        default: return "Page failed to load. Try again"
        }
    }
}
