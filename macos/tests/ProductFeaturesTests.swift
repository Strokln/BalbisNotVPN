import Foundation

@main struct ProductFeaturesTests {
    static func main() {
        precondition(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.9")!)
        precondition(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"))
        for invalid in ["v1", "v1.2-beta", "1..2", "-1.2", "1.2/evil", "1.2\n", "https://evil.com", "999999999999999999999.0"] { precondition(ReleaseVersion(invalid) == nil) }
        for (draft, prerelease, tag, accepted) in [(false, false, "v0.10.0", true), (true, false, "v0.10.0", false), (false, true, "v0.10.0", false), (false, false, "v1.0-beta", false)] {
            let data = try! JSONSerialization.data(withJSONObject: ["draft": draft, "prerelease": prerelease, "tag_name": tag] as [String: Any])
            precondition((UpdateChecker.stableTag(data) != nil) == accepted)
        }
        precondition(UpdateChecker.stableTag(Data("not-json".utf8)) == nil)
        precondition(ConnectionProblem.explain(UserFacingError(message: "Прежнее подключение восстановлено.", details: "регион недоступен")).message == "Прежнее подключение восстановлено.")
        precondition(ConnectionProblem.explain(BalbisError("Another PAC is enabled")).action == .network)
        precondition(ConnectionProblem.explain(BalbisError("Не удалось восстановить прокси")).action == .settings)
        precondition(ConnectionProblem.explain(BalbisError("служба не готова")).action == .settings)
        precondition(ConnectionProblem.explain(BalbisError("неподходящая страна")).action == .settings)
        precondition(ConnectionProblem.explain(BalbisError("timeout")).action == .retry)
        print("PASS: numeric release comparison rejects unsafe/prerelease tags; actionable connection errors")
    }
}
