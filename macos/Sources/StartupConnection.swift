import Foundation
import Network

/// Waits for a stable network once per app launch. Cancelled events cannot reconnect later.
final class StartupConnection {
    private let makeMonitor: () -> NWPathMonitor?
    private let settleDelay: TimeInterval
    private var monitor: NWPathMonitor?
    private var pending: DispatchWorkItem?
    private var completion: (() -> Void)?
    private var generation = 0
    private(set) var waiting = false

    init(settleDelay: TimeInterval = 2, makeMonitor: @escaping () -> NWPathMonitor? = { NWPathMonitor() }) {
        self.settleDelay = settleDelay
        self.makeMonitor = makeMonitor
    }

    func waitForNetwork(_ ready: @escaping () -> Void) {
        cancel()
        waiting = true
        completion = ready
        guard let next = makeMonitor() else { return }
        monitor = next
        next.pathUpdateHandler = { [weak self, weak next] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self = self, let next = next, self.monitor === next else { return }
                self.networkChanged(available: available)
            }
        }
        next.start(queue: DispatchQueue(label: "balbis.startup.network"))
    }

    // Kept separate so rapid network changes and cancellation can be verified offline.
    func networkChanged(available: Bool) {
        guard waiting else { return }
        generation += 1
        pending?.cancel()
        pending = nil
        guard available else { return }
        let ticket = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.waiting, self.generation == ticket else { return }
            let ready = self.completion
            self.cancel()
            ready?()
        }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: task)
    }

    func cancel() {
        generation += 1
        waiting = false
        pending?.cancel()
        pending = nil
        monitor?.cancel()
        monitor = nil
        completion = nil
    }

    deinit { pending?.cancel(); monitor?.cancel() }
}
