import Foundation
import Network

final class PACServer {
    private let queue = DispatchQueue(label: "balbis.pac")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let body: Data
    var onFailure: (() -> Void)?
    var isReady: Bool { queue.sync { listener?.state == .ready } }
    private(set) var port: UInt16 = 0
    let path = "/" + UUID().uuidString + "/proxy.pac"

    init(script: String) { body = Data(script.utf8) }
    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = false
        let server = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        server.stateUpdateHandler = { [weak self, weak server] state in
            switch state {
            case .ready: self?.port = server?.port?.rawValue ?? 0; ready.signal()
            case .failed(let error): startError = error; ready.signal(); self?.onFailure?()
            default: break
            }
        }
        server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener = server
        server.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { stop(); throw BalbisError("Не удалось запустить локальный PAC-сервер.") }
        if let error = startError { stop(); throw error }
        guard port > 0 else { stop(); throw BalbisError("PAC-сервер не получил порт.") }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        clients[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.clients.removeValue(forKey: key)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak connection] in connection?.cancel() }
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - accumulated.count) { [weak self] data, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var request = accumulated
            if let data = data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) == nil {
                if complete || error != nil || request.count >= 8192 { connection.cancel() }
                else { self.receive(connection, accumulated: request) }
                return
            }
            let first = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0]
            let valid = first == "GET \(self.path) HTTP/1.1" || first == "GET \(self.path) HTTP/1.0"
            let payload = valid ? self.body : Data("Not found".utf8)
            var response = Data("HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for client in clients.values { client.cancel() }
            clients.removeAll()
        }
    }
    deinit { listener?.cancel() }
}
