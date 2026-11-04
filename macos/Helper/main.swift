import Foundation
import SystemConfiguration
import Darwin

private let directory = "/Library/PrivilegedHelperTools/local.balbis.proxy"
private let socketPath = "/var/run/local.balbis.proxy.sock"
private struct Failure: Error { let text: String; init(_ text: String) { self.text = text } }
private struct Configuration: Decodable { let uid: uid_t }
private struct Journal: Codable {
    let uid: uid_t
    let serviceID: String
    let serviceName: String
    let sessionID: String
    let pacURL: String
    let original: Data
}
private let pacKeys = ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString"]

private func validURL(_ string: String) -> Bool {
    guard let u = URLComponents(string: string), u.scheme == "http", u.host == "127.0.0.1",
          let port = u.port, (1...65535).contains(port), u.user == nil, u.password == nil,
          u.query == nil, u.fragment == nil else { return false }
    let parts = u.path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].isEmpty, parts[2] == "proxy.pac", UUID(uuidString: String(parts[1])) != nil else { return false }
    return string == "http://127.0.0.1:\(port)/\(parts[1])/proxy.pac"
}
private func enabled(_ value: Any?) -> Bool { (value as? NSNumber)?.intValue != 0 && value != nil }
private func validateOriginal(_ p: [String: Any], url: String) throws {
    for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoDiscoveryEnable"] {
        if enabled(p[key]) { throw Failure("Conflicting proxy configuration") }
    }
    if enabled(p["ProxyAutoConfigEnable"]) {
        throw Failure("Another PAC is enabled")
    }
}
// Restore just the two PAC keys. Other changes made since installation survive.
private func restored(_ current: [String: Any], original: [String: Any]) -> [String: Any] {
    var result = current
    for key in pacKeys { result.removeValue(forKey: key); if let value = original[key] {
        if key != "ProxyAutoConfigURLString" || (value as? String) != "" { result[key] = value }
    } }
    return result
}
private func secureStat(_ path: String, directory: Bool) throws {
    var s = stat()
    guard lstat(path, &s) == 0, s.st_uid == 0, s.st_mode & 0o022 == 0,
          s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw Failure("Insecure helper storage: \(path)") }
}
private func configuration() throws -> Configuration {
    try secureStat("/Library", directory: true)
    try secureStat("/Library/PrivilegedHelperTools", directory: true)
    try secureStat(directory, directory: true)
    try secureStat(directory + "/config.json", directory: false)
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/config.json")))
    guard config.uid != 0 else { throw Failure("Invalid authorized UID") }
    return config
}
private func loadJournal() throws -> Journal? {
    let path = directory + "/journal.json"
    var s = stat()
    if lstat(path, &s) != 0 { if errno == ENOENT { return nil }; throw Failure("Cannot inspect journal") }
    try secureStat(path, directory: false)
    return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}
private func persist(_ journal: Journal) throws {
    let bytes = try JSONEncoder().encode(journal)
    let temp = directory + "/journal.\(UUID().uuidString).tmp"
    let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Failure("Cannot create journal") }
    defer { close(fd); unlink(temp) }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard n > 0 else { throw Failure("Cannot write journal") }; offset += n
        }
    }
    guard fsync(fd) == 0, rename(temp, directory + "/journal.json") == 0 else { throw Failure("Cannot persist journal") }
    try syncDirectory()
}
private func syncDirectory() throws {
    let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure("Cannot open state directory") }; defer { close(fd) }
    guard fsync(fd) == 0 else { throw Failure("Cannot sync state directory") }
}
private func removeJournal() throws {
    guard unlink(directory + "/journal.json") == 0 || errno == ENOENT else { throw Failure("Cannot remove journal") }
    try syncDirectory()
}
private func handle(_ request: HelperRequest, uid: uid_t) throws -> String {
    guard ["ping", "install", "restore"].contains(request.operation) else { throw Failure("Unsupported operation") }
    if request.operation == "ping" { return String(helperProtocolVersion) }
    guard validURL(request.pacURL), UUID(uuidString: request.sessionID) != nil,
          !request.service.isEmpty, request.service.utf8.count < 1024 else { throw Failure("Invalid request") }
    guard let preferences = SCPreferencesCreate(nil, "Balbis Proxy Helper" as CFString, nil),
          SCPreferencesLock(preferences, true) else { throw Failure("Cannot lock network preferences") }
    defer { SCPreferencesUnlock(preferences) }
    let journal = try loadJournal()
    if let j = journal {
        guard j.uid == uid, j.sessionID == request.sessionID, j.pacURL == request.pacURL,
              j.serviceName == request.service else { throw Failure("Another session owns proxy state") }
    } else if request.operation == "restore" { return "no-session" }
    let services = (SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]) ?? []
    let service: SCNetworkService
    if let j = journal {
        guard let found = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == j.serviceID }) else {
            if request.operation == "restore" { try removeJournal(); return "restored" }
            throw Failure("Network service disappeared")
        }; service = found
    } else {
        let matches = services.filter { SCNetworkServiceGetEnabled($0) && (SCNetworkServiceGetName($0) as String?) == request.service }
        guard matches.count == 1 else { throw Failure("Enabled network service must match exactly") }; service = matches[0]
    }
    guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { throw Failure("No proxy protocol") }
    let current = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
    var updated: [String: Any]
    if request.operation == "install" {
        if journal != nil {
            if current["ProxyAutoConfigURLString"] as? String == request.pacURL && enabled(current["ProxyAutoConfigEnable"]) {
                guard SCPreferencesApplyChanges(preferences) else { throw Failure("Cannot apply proxy preferences; journal retained") }
                return "installed"
            }
            // A retry after a crash before apply is allowed only while original PAC keys remain intact.
            guard let original = try PropertyListSerialization.propertyList(from: journal!.original, format: nil) as? [String: Any] else { throw Failure("Invalid original configuration") }
            let a = NSDictionary(dictionary: current.filter { pacKeys.contains($0.key) })
            let b = NSDictionary(dictionary: original.filter { pacKeys.contains($0.key) })
            guard a == b else { throw Failure("Proxy state changed since journal capture") }
        }
        try validateOriginal(current, url: request.pacURL)
        if journal == nil {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else { throw Failure("Missing service ID") }
            let original = try PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0)
            try persist(Journal(uid: uid, serviceID: serviceID,
                serviceName: request.service, sessionID: request.sessionID, pacURL: request.pacURL, original: original))
        }
        updated = current; updated["ProxyAutoConfigEnable"] = 1; updated["ProxyAutoConfigURLString"] = request.pacURL
    } else {
        guard current["ProxyAutoConfigURLString"] as? String == request.pacURL else {
            // Commit may have succeeded just before a previous process crashed during apply.
            // Re-applying the current committed preferences also respects superseding settings.
            guard SCPreferencesApplyChanges(preferences) else { throw Failure("Cannot apply current preferences; journal retained") }
            try removeJournal(); return "restored"
        }
        guard let original = try PropertyListSerialization.propertyList(from: journal!.original, format: nil) as? [String: Any] else { throw Failure("Invalid original configuration") }
        updated = restored(current, original: original)
    }
    guard SCNetworkProtocolSetConfiguration(proto, updated as CFDictionary), SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw Failure("Cannot apply proxy preferences; journal retained") }
    if request.operation == "restore" { try removeJournal(); return "restored" }
    return "installed"
}
private func serveConnection(_ client: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let response: HelperResponse
    do {
        let config = try configuration()
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == config.uid else { throw Failure("Unauthorized peer") }
        var data = Data(); var complete = false
        // Read one bounded line; the absolute deadline also prevents slow trickle clients.
        let deadline = Date().addingTimeInterval(5)
        while data.count < 16384 && Date() < deadline {
            let remaining = max(0.001, deadline.timeIntervalSinceNow)
            var readTimeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            guard read(client, &byte, 1) == 1 else { break }
            if byte == 10 { complete = true; break }
            data.append(byte)
        }
        guard complete else { throw Failure("Request too large or incomplete") }
        let request = try JSONDecoder().decode(HelperRequest.self, from: data)
        response = HelperResponse(success: true, message: try handle(request, uid: uid))
    } catch {
        response = HelperResponse(success: false, message: (error as? Failure)?.text ?? "Helper request failed")
    }
    if var bytes = try? JSONEncoder().encode(response) {
        bytes.append(10)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }; offset += n
            }
        }
    }
}
private func run() throws {
    guard geteuid() == 0 else { throw Failure("Helper must run as root") }
    let config = try configuration()
    // A process lock prevents a second daemon from unlinking an active listener.
    let lock = open(directory + "/daemon.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw Failure("Cannot open daemon lock") }; defer { close(lock) }
    try secureStat(directory + "/daemon.lock", directory: false)
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Helper already running") }
    var previous = stat()
    if lstat(socketPath, &previous) == 0 {
        guard previous.st_mode & S_IFMT == S_IFSOCK else { throw Failure("Unexpected socket path") }
        guard unlink(socketPath) == 0 else { throw Failure("Cannot replace socket") }
    } else if errno != ENOENT { throw Failure("Cannot inspect socket") }
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw Failure("Cannot create socket") }; defer { close(server); unlink(socketPath) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: path) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let oldMask = umask(0o077)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(oldMask)
    guard bound == 0, chown(socketPath, config.uid, 0) == 0, chmod(socketPath, 0o600) == 0,
          listen(server, 8) == 0 else { throw Failure("Cannot bind protected socket") }
    while true {
        let client = accept(server, nil, nil)
        if client < 0 { if errno == EINTR { continue }; throw Failure("Accept failed") }
        serveConnection(client); close(client)
    }
}
// Root-only installer probe. Never creates/removes state or touches networking.
private func checkStopped() throws {
    guard geteuid() == 0 else { throw Failure("Stopped-state check requires root") }
    try secureStat("/Library", directory: true)
    try secureStat("/Library/PrivilegedHelperTools", directory: true)
    var info = stat()
    if lstat(directory, &info) != 0 {
        guard errno == ENOENT else { throw Failure("Cannot inspect helper directory") }
        return
    }
    try secureStat(directory, directory: true)
    let path = directory + "/daemon.lock"
    if lstat(path, &info) != 0 {
        guard errno == ENOENT else { throw Failure("Cannot inspect daemon lock") }
        return
    }
    try secureStat(path, directory: false)
    let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure("Cannot open daemon lock") }
    defer { close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0, opened.st_uid == 0, opened.st_mode & 0o022 == 0,
          opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == info.st_dev,
          opened.st_ino == info.st_ino else { throw Failure("Unsafe daemon lock") }
    let deadline = Date().addingTimeInterval(5)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw Failure("Cannot check daemon lock") }
        guard Date() < deadline else { throw Failure("Helper is still running") }
        usleep(50_000)
    }
}
private func selfTest() throws {
    let url = "http://127.0.0.1:8080/00000000-0000-0000-0000-000000000000/proxy.pac"
    guard validURL(url) else { throw Failure("URL positive test") }
    for bad in [url + "?x", url + "#x", url.replacingOccurrences(of: "127.0.0.1", with: "localhost"), url.replacingOccurrences(of: "8080", with: "0"), url.replacingOccurrences(of: "http:", with: "https:"), url.replacingOccurrences(of: "/proxy.pac", with: "/extra/proxy.pac")] {
        guard !validURL(bad) else { throw Failure("URL negative test") }
    }
    for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoDiscoveryEnable"] {
        do { try validateOriginal([key: 1], url: url); throw Failure("Conflict test") }
        catch let e as Failure { guard e.text == "Conflicting proxy configuration" else { throw e } }
    }
    do {
        try validateOriginal(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://different.invalid/pac"], url: url)
        throw Failure("Different PAC test")
    } catch let e as Failure { guard e.text == "Another PAC is enabled" else { throw e } }
    do {
        try validateOriginal(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": url], url: url)
        throw Failure("Same URL PAC capture test")
    } catch let e as Failure { guard e.text == "Another PAC is enabled" else { throw e } }
    let original: [String: Any] = ["ProxyAutoConfigEnable": 0, "HTTPEnable": 0]
    let result = restored(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": url, "ExceptionsList": ["new"]], original: original)
    guard result["ProxyAutoConfigURLString"] == nil, result["ProxyAutoConfigEnable"] as? Int == 0,
          result["ExceptionsList"] as? [String] == ["new"] else { throw Failure("Restore preservation test") }
    let prior: [String: Any] = ["ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": ""]
    guard restored([:], original: prior)["ProxyAutoConfigURLString"] == nil else { throw Failure("Empty prior URL test") }
    let nonempty: [String: Any] = ["ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "https://prior.invalid/proxy.pac"]
    guard NSDictionary(dictionary: restored([:], original: nonempty)) == NSDictionary(dictionary: nonempty) else { throw Failure("Exact prior PAC test") }
    print("Helper offline tests passed")
}
do {
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] { try selfTest() }
    else if CommandLine.arguments == [CommandLine.arguments[0], "--check-stopped"] { try checkStopped() }
    else if CommandLine.arguments.count == 1 { try run() }
    else { throw Failure("Unsupported arguments") }
} catch {
    fputs("Balbis helper: \((error as? Failure)?.text ?? String(describing: error))\n", stderr)
    exit(1)
}
