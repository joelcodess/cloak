import Foundation
import Network
import CloakKit

// MARK: - Local Anthropic-compatible scrubbing proxy
//
// The interception point the feasibility study landed on: point Claude Code's
// ANTHROPIC_BASE_URL at this localhost server. It receives the SAME requests
// Claude Code would send to api.anthropic.com (POST /v1/messages?beta=true),
// scrubs the outbound body on-device, forwards to the real API with the real
// key, and rehydrates the streamed SSE response on the way back.
//
// Transport notes:
//  - Inbound is plain HTTP on localhost (Claude Code talks HTTP to the base
//    URL; TLS is only on the OUTBOUND hop to api.anthropic.com via URLSession).
//  - We answer with `Connection: close` and stream the body until EOF — simple
//    and robust for SSE without hand-rolling chunked framing.
//
// STATUS: the scrub engine + eval loop are exercised directly via `cloak scrub`.
// This proxy needs a live Claude Code session + real API key to validate
// end-to-end; the streaming rehydration logic is built but not yet road-tested.

private let UPSTREAM = "https://api.anthropic.com"

actor Proxy {
    let port: UInt16
    private let engine = ScrubEngine()
    private let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]

    init(port: UInt16) { self.port = port }

    func run() async {
        if FoundationModelSpanFinder.availabilityError() != nil {
            FileHandle.standardError.write(Data("⚠️  on-device model unavailable — proxy will forward WITHOUT scrubbing.\n".utf8))
        }
        let params = NWParameters.tcp
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            FileHandle.standardError.write(Data("✗ could not bind port \(port)\n".utf8)); return
        }
        listener.newConnectionHandler = { conn in
            Task { await self.handle(conn) }
        }
        listener.start(queue: .global())
        FileHandle.standardError.write(Data("""
        🧥 cloak proxy listening on http://localhost:\(port)
           run:  ANTHROPIC_BASE_URL=http://localhost:\(port) claude

        """.utf8))
        // Park forever.
        while true { try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
    }

    private func handle(_ conn: NWConnection) async {
        conn.start(queue: .global())
        guard let req = await readRequest(conn) else { conn.cancel(); return }
        await route(req, on: conn)
    }

    // MARK: Request reading

    private struct HTTPRequest {
        var method: String
        var target: String          // path + query
        var headers: [(String, String)]
        var body: Data
    }

    private func readRequest(_ conn: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        // Read until we have the header terminator.
        while true {
            guard let chunk = await receive(conn) else { return nil }
            buffer.append(chunk)
            if let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                guard let head = String(data: headerData, encoding: .utf8) else { return nil }
                var lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst().split(separator: " ")
                guard requestLine.count >= 2 else { return nil }
                let method = String(requestLine[0])
                let target = String(requestLine[1])
                var headers: [(String, String)] = []
                var contentLength = 0
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers.append((name, value))
                    if name.lowercased() == "content-length" { contentLength = Int(value) ?? 0 }
                }
                var body = buffer.subdata(in: r.upperBound..<buffer.endIndex)
                while body.count < contentLength {
                    guard let more = await receive(conn) else { break }
                    body.append(more)
                }
                return HTTPRequest(method: method, target: target, headers: headers, body: body)
            }
            if buffer.count > 64 * 1024 * 1024 { return nil }   // sanity cap
        }
    }

    private func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    // MARK: Routing

    private func route(_ req: HTTPRequest, on conn: NWConnection) async {
        let isMessages = req.target.hasPrefix("/v1/messages")
        var bodyToSend = req.body
        var map = SubstitutionMap()
        let scrubbing = isMessages && req.method == "POST" && FoundationModelSpanFinder.availabilityError() == nil

        if scrubbing {
            (bodyToSend, map) = await MessagesScrub.scrubRequestBody(req.body, engine: engine)
        }

        // Detect streaming from the (original) request body.
        let wantsStream = (try? JSONSerialization.jsonObject(with: req.body))
            .flatMap { ($0 as? [String: Any])?["stream"] as? Bool } ?? false

        await forward(req, body: bodyToSend, map: map, stream: wantsStream, rehydrate: scrubbing, on: conn)
    }

    private func forward(_ req: HTTPRequest, body: Data, map: SubstitutionMap,
                         stream: Bool, rehydrate: Bool, on conn: NWConnection) async {
        guard let url = URL(string: UPSTREAM + req.target) else { await sendError(conn, 502, "bad upstream url"); return }
        var ureq = URLRequest(url: url)
        ureq.httpMethod = req.method
        ureq.httpBody = body
        // Forward headers verbatim except hop-by-hop / length / host, then
        // inject the real key (held by the proxy, never given to the model).
        for (name, value) in req.headers {
            let lower = name.lowercased()
            if ["host", "content-length", "connection", "accept-encoding"].contains(lower) { continue }
            ureq.setValue(value, forHTTPHeaderField: name)
        }
        ureq.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        if let apiKey { ureq.setValue(apiKey, forHTTPHeaderField: "x-api-key") }

        do {
            if stream {
                try await streamResponse(ureq, map: map, rehydrate: rehydrate, on: conn)
            } else {
                try await bufferedResponse(ureq, map: map, rehydrate: rehydrate, on: conn)
            }
        } catch {
            await sendError(conn, 502, "upstream error: \(error.localizedDescription)")
        }
    }

    // MARK: Non-streaming response

    private func bufferedResponse(_ ureq: URLRequest, map: SubstitutionMap, rehydrate: Bool, on conn: NWConnection) async throws {
        let (data, response) = try await URLSession.shared.data(for: ureq)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var outData = data
        // Rehydrate text fields in the JSON response body.
        if rehydrate, status == 200, var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let r = StreamingRehydrator(map: map)
            if var content = root["content"] as? [[String: Any]] {
                for i in content.indices where (content[i]["type"] as? String) == "text" {
                    if let t = content[i]["text"] as? String {
                        var s = r.feed(t); s += r.flush()
                        content[i]["text"] = s
                    }
                }
                root["content"] = content
            }
            if let re = try? JSONSerialization.data(withJSONObject: root, options: []) { outData = re }
        }
        let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        header += "Content-Type: \(ct)\r\n"
        header += "Content-Length: \(outData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        await sendRaw(conn, Data(header.utf8) + outData)
        conn.cancel()
    }

    // MARK: Streaming (SSE) response

    private func streamResponse(_ ureq: URLRequest, map: SubstitutionMap, rehydrate: Bool, on conn: NWConnection) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: ureq)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        header += "Content-Type: text/event-stream\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"
        await sendRaw(conn, Data(header.utf8))

        // Per-content-block rehydrator: flush the carry-over tail at block stop.
        var rehydrator = StreamingRehydrator(map: map)

        for try await line in bytes.lines {
            // SSE is line-oriented; we only transform `data:` lines carrying a
            // text_delta, and flush on content_block_stop. Everything else is
            // forwarded verbatim to preserve event framing.
            if rehydrate, line.hasPrefix("data:") {
                let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let out = transformSSEData(json, rehydrator: &rehydrator, map: map) {
                    await sendRaw(conn, Data("data: \(out)\r\n".utf8))
                    continue
                }
            }
            await sendRaw(conn, Data((line + "\r\n").utf8))
        }
        // Final flush in case the stream ended without a content_block_stop.
        let tail = rehydrator.flush()
        if !tail.isEmpty {
            let evt = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(jsonString(tail))}}"#
            await sendRaw(conn, Data("data: \(evt)\r\n\r\n".utf8))
        }
        conn.cancel()
    }

    /// Returns a rewritten JSON string for a `data:` payload, or nil to forward
    /// the line verbatim. Handles text_delta (rehydrate) and content_block_stop
    /// (flush the carry-over tail into a synthetic delta first).
    private func transformSSEData(_ json: String, rehydrator: inout StreamingRehydrator, map: SubstitutionMap) -> String? {
        guard let data = json.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "content_block_delta":
            guard var delta = obj["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            delta["text"] = rehydrator.feed(text)
            obj["delta"] = delta
            return serialize(obj)
        case "content_block_stop":
            // Drain the tail before the block closes; emit it as its own delta.
            let tail = rehydrator.flush()
            rehydrator = StreamingRehydrator(map: map)   // reset for next block
            if tail.isEmpty { return nil }
            let idx = obj["index"] as? Int ?? 0
            let deltaEvt = #"{"type":"content_block_delta","index":\#(idx),"delta":{"type":"text_delta","text":\#(jsonString(tail))}}"#
            // Emit the flushed delta, then let the stop line follow verbatim.
            return deltaEvt + "\r\n\r\ndata: " + json
        default:
            return nil
        }
    }

    // MARK: Low-level write helpers

    private func sendRaw(_ conn: NWConnection, _ data: Data) async {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private func sendError(_ conn: NWConnection, _ status: Int, _ msg: String) async {
        let body = Data(#"{"type":"error","error":{"type":"proxy_error","message":"\#(msg)"}}"#.utf8)
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        await sendRaw(conn, Data(header.utf8) + body)
        conn.cancel()
    }

    private func serialize(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func jsonString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var str = String(data: d, encoding: .utf8) ?? "[\"\"]"
        str.removeFirst(); str.removeLast()        // strip the [ ]
        return str
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"; case 400: return "Bad Request"; case 401: return "Unauthorized"
        case 429: return "Too Many Requests"; case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"; default: return "Status"
        }
    }
}
