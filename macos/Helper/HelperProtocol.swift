import Foundation

let helperProtocolVersion = 1
struct HelperRequest: Codable {
    let operation: String
    let service: String
    let pacURL: String
    let sessionID: String
}
struct HelperResponse: Codable {
    let success: Bool
    let message: String
}
