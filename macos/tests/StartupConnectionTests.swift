import Foundation

@main
struct StartupConnectionTests {
    static func drain(_ duration: TimeInterval = 0.035) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
    static func main() {
        let startup = StartupConnection(settleDelay: 0.01, makeMonitor: { nil })
        var connections = 0
        startup.waitForNetwork { connections += 1 }
        startup.networkChanged(available: false)
        drain()
        precondition(connections == 0 && startup.waiting)
        startup.networkChanged(available: true)
        startup.networkChanged(available: false)
        drain()
        precondition(connections == 0, "Losing the network must cancel a scheduled connection")
        startup.networkChanged(available: true)
        startup.networkChanged(available: true)
        drain()
        precondition(connections == 1 && !startup.waiting, "Startup must only connect once")
        startup.networkChanged(available: true)
        drain()
        precondition(connections == 1)
        startup.waitForNetwork { connections += 10 }
        startup.networkChanged(available: true)
        startup.cancel()
        drain()
        precondition(connections == 1 && !startup.waiting, "Cancelling startup must prevent later callbacks")
        startup.waitForNetwork { connections += 100 }
        startup.networkChanged(available: true)
        startup.waitForNetwork { connections += 1 }
        drain()
        precondition(connections == 1, "Replacing a pending attempt must invalidate the old callback")
        startup.networkChanged(available: true)
        drain()
        precondition(connections == 2)
        print("PASS: startup waits for network, debounces changes, connects once and respects cancellation")
    }
}
