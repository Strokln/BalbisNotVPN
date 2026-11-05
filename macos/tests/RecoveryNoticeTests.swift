import Foundation

@main
struct RecoveryNoticeTests {
    static func main() {
        var policy = RecoveryNoticePolicy()
        precondition(!policy.recordFailure())
        precondition(!policy.recordFailure())
        precondition(policy.recordFailure())
        for _ in 0..<10 { precondition(!policy.recordFailure(), "One notice per failure episode") }
        policy.reset()
        precondition(!policy.recordFailure(), "Manual stop/success resets old episode")
        precondition(!policy.recordFailure())
        precondition(policy.recordFailure(), "A new outage can notify again")
        print("PASS: recovery notices wait for repeated failures and never spam one episode")
    }
}
