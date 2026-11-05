import Foundation
import Darwin

@main struct AutomaticExitSelectionTests {
    static func main() throws {
        let eu = ExitCandidateScore(region: "EU", seconds: 0.8, downloadedBytes: 200)
        let am = ExitCandidateScore(region: "AM", seconds: 0.3, downloadedBytes: 210)
        precondition(ExitSelectionPolicy.orderedRegions([eu, am]) == ["AM", "EU"])
        precondition(ExitSelectionPolicy.orderedRegions([eu]) == ["EU", "AM"])
        precondition(ExitSelectionPolicy.orderedRegions([am]) == ["AM", "EU"])
        precondition(ExitSelectionPolicy.orderedRegions([]) == ["EU", "AM"])
        precondition(ExitSelectionPolicy.orderedRegions([am, am, eu]) == ["AM", "EU"])
        precondition(ExitSelectionPolicy.orderedRegions([eu, ExitCandidateScore(region: "AM", seconds: 0.8, downloadedBytes: 210)]) == ["EU", "AM"])
        for invalid in [ExitCandidateScore(region: "AM", seconds: .nan, downloadedBytes: 200), ExitCandidateScore(region: "AM", seconds: -1, downloadedBytes: 200), ExitCandidateScore(region: "AM", seconds: .infinity, downloadedBytes: 200), ExitCandidateScore(region: "AM", seconds: 0.01, downloadedBytes: 0), ExitCandidateScore(region: "AM", seconds: 0.01, downloadedBytes: 5000), ExitCandidateScore(region: "unknown", seconds: 0.01, downloadedBytes: 200)] {
            precondition(ExitSelectionPolicy.orderedRegions([invalid, eu]) == ["EU", "AM"])
        }
        let lowLatencySlowDownload = ExitCandidateScore(region: "EU", seconds: 0.1, downloadedBytes: 200, bytesPerSecond: 16_384)
        let higherLatencyFastDownload = ExitCandidateScore(region: "AM", seconds: 0.3, downloadedBytes: 200, bytesPerSecond: 524_288)
        precondition(ExitSelectionPolicy.orderedRegions([lowLatencySlowDownload, higherLatencyFastDownload]) == ["AM", "EU"])
        precondition(ExitSelectionPolicy.orderedRegions([lowLatencySlowDownload, am]) == ["AM", "EU"])
        let invalidRate = ExitCandidateScore(region: "AM", seconds: 0.3, downloadedBytes: 200, bytesPerSecond: .nan)
        precondition(ExitSelectionPolicy.orderedRegions([eu, invalidRate]) == ["AM", "EU"])
        let owner = ExitCandidateProcesses()
        let sleeper = try owner.launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        do {
            try owner.launch(URL(fileURLWithPath: "/nonexistent/balbis-test-executable"), [])
            preconditionFailure("Expected launch failure")
        } catch { owner.stop() }
        precondition(!sleeper.isRunning && owner.children.isEmpty)
        owner.stop() // Repeated cleanup is safe.
        let stubbornOwner = ExitCandidateProcesses()
        let stubborn = try stubbornOwner.launch(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; exec /bin/sleep 60"])
        usleep(100_000)
        let before = ProcessInfo.processInfo.systemUptime
        stubbornOwner.stop()
        precondition(!stubborn.isRunning && ProcessInfo.processInfo.systemUptime - before < 5)
        var doomed: Process!
        do {
            let temporary = ExitCandidateProcesses()
            doomed = try temporary.launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        }
        precondition(!doomed.isRunning)
        print("Automatic exit selection tests passed")
    }
}
