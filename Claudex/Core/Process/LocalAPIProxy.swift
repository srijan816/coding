//
//  LocalAPIProxy.swift
//  Claudex
//
//  Local HTTP proxy that intercepts claude CLI API calls and forwards them
//  to the actual backend while broadcasting events to the UI.
//

import Foundation
import Network

// MARK: - API Event

enum APIEvent: Equatable {
    case request(RequestInfo)
    case response(ResponseInfo)
    case error(String)
}

struct RequestInfo: Equatable {
    let id: UUID
    let method: String
    let path: String
    let body: Data?
    let headers: [String: String]
    let timestamp: Date
}

struct ResponseInfo: Equatable {
    let requestId: UUID
    let statusCode: Int
    let body: Data?
    let headers: [String: String]
    let timestamp: Date
}

// MARK: - LocalAPIProxy

final class LocalAPIProxy: @unchecked Sendable {
    private let proxy: NWListener
    private var _port: UInt16 = 0
    private let targetHost: String
    private let targetPort: UInt16
    private let authToken: String

    private var connections: [NWConnection] = []
    private let connectionLock = NSLock()

    private var portContinuation: AsyncStream<UInt16>.Continuation?

    var events: AsyncStream<APIEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    private var eventContinuation: AsyncStream<APIEvent>.Continuation?

    /// Stream that emits the port once the proxy is ready
    var portStream: AsyncStream<UInt16> {
        AsyncStream { continuation in
            self.portContinuation = continuation
        }
    }

    init(targetHost: String, targetPort: UInt16, authToken: String) throws {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.authToken = authToken

        // Find an available port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 0)!)
        self.proxy = listener

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let port = listener.port?.rawValue {
                    self?._port = port
                    Logger.shared.info("LocalAPIProxy listening on port \(port)")
                    self?.portContinuation?.yield(port)
                }
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
    }

    var port: UInt16 { _port }

    func start() {
        proxy.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        proxy.cancel()
        connectionLock.lock()
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        connectionLock.unlock()
    }

    private func handleConnection(_ conn: NWConnection) {
        connectionLock.lock()
        connections.append(conn)
        connectionLock.unlock()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: conn)
            case .failed(let err):
                Logger.shared.warn("LocalAPIProxy connection failed: \(err)")
            case .cancelled:
                Logger.shared.info("LocalAPIProxy connection cancelled")
            default:
                break
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
    }

    private func receiveRequest(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                Logger.shared.error("LocalAPIProxy receive error: \(error)")
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    conn.cancel()
                }
                return
            }

            // Parse the HTTP request
            guard let request = self.parseRequest(data: data) else {
                self.forwardRequest(data: data, to: conn)
                return
            }

            let requestId = UUID()
            let timestamp = Date()

            // Emit request event
            let headers = request.headers.reduce(into: [String: String]()) { $0[$1.key] = $1.value }
            self.eventContinuation?.yield(.request(RequestInfo(
                id: requestId,
                method: request.method,
                path: request.path,
                body: request.body,
                headers: headers,
                timestamp: timestamp
            )))

            // Forward to target
            self.forwardToTarget(request: request, requestId: requestId) { responseData, statusCode, responseHeaders in
                // Emit response event
                let respHeaders = responseHeaders.reduce(into: [String: String]()) { $0[$1.key] = $1.value }
                self.eventContinuation?.yield(.response(ResponseInfo(
                    requestId: requestId,
                    statusCode: statusCode,
                    body: responseData,
                    headers: respHeaders,
                    timestamp: Date()
                )))

                // Send response back to client
                if let responseData = responseData {
                    let httpResponse = self.buildHTTPResponse(statusCode: statusCode, headers: respHeaders, body: responseData)
                    conn.send(content: httpResponse, completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                } else {
                    let httpResponse = self.buildHTTPResponse(statusCode: 502, headers: [:], body: "Bad Gateway".data(using: .utf8)!)
                    conn.send(content: httpResponse, completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let httpVersion: String
        let headers: [(key: String, value: String)]
        let body: Data?
    }

    private func parseRequest(data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let path = String(requestParts[1])
        let httpVersion = requestParts.count > 2 ? String(requestParts[2]) : "HTTP/1.1"

        var headers: [(key: String, value: String)] = []
        var bodyStartIndex = 0
        for (i, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStartIndex = i + 2
                break
            }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers.append((
                    key: String(headerParts[0]).trimmingCharacters(in: .whitespaces),
                    value: String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                ))
            }
        }

        var body: Data?
        if bodyStartIndex > 0 && bodyStartIndex < lines.count {
            let bodyText = lines[bodyStartIndex...].joined(separator: "\r\n")
            body = bodyText.data(using: .utf8)
        }

        return ParsedRequest(method: method, path: path, httpVersion: httpVersion, headers: headers, body: body)
    }

    private func forwardToTarget(request: ParsedRequest, requestId: UUID, completion: @escaping (Data?, Int, [(key: String, value: String)]) -> Void) {
        guard let targetURL = URL(string: "https://\(targetHost):\(targetPort)\(request.path)") else {
            completion(nil, 502, [])
            return
        }

        var targetRequest = URLRequest(url: targetURL)
        targetRequest.httpMethod = request.method

        var headers: [(key: String, value: String)] = []
        for (key, value) in request.headers {
            if ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"].contains(key.lowercased()) {
                continue
            }
            targetRequest.setValue(value, forHTTPHeaderField: key)
            headers.append((key: key, value: value))
        }

        // Add auth
        if !authToken.isEmpty {
            targetRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "x-api-key")
            targetRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        targetRequest.httpBody = request.body

        let task = URLSession.shared.dataTask(with: targetRequest) { data, response, error in
            if let error = error {
                Logger.shared.error("LocalAPIProxy forward error: \(error)")
                completion(nil, 502, [])
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 502
            let responseHeaders = httpResponse?.allHeaderFields.reduce(into: [(key: String, value: String)]()) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    result.append((key: key, value: value))
                }
            } ?? []

            completion(data, statusCode, responseHeaders)
        }
        task.resume()
    }

    private func buildHTTPResponse(statusCode: Int, headers: [String: String], body: Data) -> Data {
        var response = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"

        for (key, value) in headers {
            if ["transfer-encoding", "connection"].contains(key.lowercased()) { continue }
            response += "\(key): \(value)\r\n"
        }

        response += "Content-Length: \(body.count)\r\n"
        response += "\r\n"

        var data = response.data(using: .utf8)!
        data.append(body)
        return data
    }

    private func forwardRequest(data: Data, to conn: NWConnection) {
        forwardToTarget(request: parseRequest(data: data) ?? ParsedRequest(method: "GET", path: "/", httpVersion: "HTTP/1.1", headers: [], body: nil), requestId: UUID()) { _, _, _ in
            let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".data(using: .utf8)!
            conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
