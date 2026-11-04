import Foundation

@main struct ConnectionHealthTests {
    static func main() {
        for status in [100, 200, 204, 301, 401, 403, 429, 500, 503, 599] {
            precondition(ConnectionHealth.provesTransport(exitStatus: 0, httpStatus: status), "HTTP \(status) proves transport")
        }
        for status in [0, 99, 600, -1] {
            precondition(!ConnectionHealth.provesTransport(exitStatus: 0, httpStatus: status))
        }
        precondition(!ConnectionHealth.provesTransport(exitStatus: 7, httpStatus: 200))
        precondition(!ConnectionHealth.provesTransport(exitStatus: 28, httpStatus: 0))
        var policy = HealthFailurePolicy()
        precondition(!policy.record(success: false))
        precondition(!policy.record(success: false))
        precondition(policy.record(success: true) == false && policy.failures == 0)
        precondition(!policy.record(success: false))
        precondition(!policy.record(success: false))
        precondition(policy.record(success: false))
        precondition(policy.record(success: false) && policy.failures == 3)
        policy.reset()
        precondition(policy.failures == 0 && !policy.record(success: false))
        print("Connection health tests passed")
    }
}
