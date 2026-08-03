import Foundation
import Darwin

func decodeFormQueryComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "+", with: " ")
        .removingPercentEncoding ?? value
}

func decodeQueryComponentPreservingPlus(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}

func parseFormQuery(_ queryString: String) -> [String: String] {
    // Tolerant path extraction:
    // Some clients may send `path` without escaping `&`, e.g.
    // `path=/Users/.../Adam Ten & Rafael...&id=...`
    // In that case naive split-by-& truncates the path.
    if let pathStart = queryString.range(of: "path=")?.upperBound {
        let tail = String(queryString[pathStart...])
        // ВСЕ параметры, которые клиенты дописывают после `path`. Список должен покрывать их
        // целиком: пропущенный ключ означает, что `path` съест хвост запроса и файл «исчезнет»
        // (404 на существующий трек). Так вело себя `&src=`/`&fmt=`/`&token=` — они здесь
        // отсутствовали, и порядок параметров у клиента становился негласным контрактом.
        let terminators = ["&id=", "&preload=", "&code=", "&limit=", "&use_key=",
                           "&src=", "&raw=", "&fmt=", "&token=", "&session=", "&lan_token=",
                           "&dl="]
        var endIndex = tail.endIndex
        for term in terminators {
            if let r = tail.range(of: term), r.lowerBound < endIndex {
                endIndex = r.lowerBound
            }
        }
        let rawPathValue = String(tail[..<endIndex])
        if rawPathValue.contains("&") && !rawPathValue.contains("%26") {
            var safe = [String: String]()
            safe["path"] = decodeQueryComponentPreservingPlus(rawPathValue)

            // Parse the rest (non-path pairs) via regular parser.
            var rest = queryString
            if let pathRange = queryString.range(of: "path=\(rawPathValue)") {
                rest.removeSubrange(pathRange)
                rest = rest.replacingOccurrences(of: "&&", with: "&")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "&"))
            }
            if !rest.isEmpty {
                for pair in rest.split(separator: "&", omittingEmptySubsequences: true) {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard !parts.isEmpty else { continue }
                    let rawKey = String(parts[0])
                    let rawValue = parts.count > 1 ? String(parts[1]) : ""
                    let key = decodeFormQueryComponent(rawKey)
                    let value = key == "path"
                        ? decodeQueryComponentPreservingPlus(rawValue)
                        : decodeFormQueryComponent(rawValue)
                    safe[key] = value
                }
            }
            return safe
        }
    }

    var query = [String: String]()

    for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let rawKey = String(parts[0])
        let rawValue = parts.count > 1 ? String(parts[1]) : ""
        let key = decodeFormQueryComponent(rawKey)
        // For file paths in query string, keep literal '+' characters.
        // Some clients send '+' unescaped in URLs, and converting it to space
        // breaks file resolution (e.g. "A+B.wav" -> "A B.wav").
        let value = key == "path"
            ? decodeQueryComponentPreservingPlus(rawValue)
            : decodeFormQueryComponent(rawValue)
        query[key] = value
    }

    return query
}

// Lightweight HTTP/1.1 server using POSIX sockets + GCD
// Supports: Range requests, chunked streaming, binary responses

final class HTTPServer {
    let port: UInt16
    private var serverFd: Int32 = -1
    private var running  = false
    private let queue    = DispatchQueue(label: "rimeo.http", qos: .userInitiated,
                                         attributes: .concurrent)
    var router: ((HTTPRequest) -> HTTPResponse)?

    init(port: UInt16) { self.port = port }

    func start() throws {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw HTTPServerError.socketFailed }

        var opt: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverFd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr         = sockaddr_in()
        addr.sin_family  = sa_family_t(AF_INET)
        addr.sin_port    = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw HTTPServerError.bindFailed(String(cString: strerror(errno))) }
        guard listen(serverFd, 128) == 0 else { throw HTTPServerError.listenFailed }

        running = true
        queue.async { self.acceptLoop() }
        logger.info("HTTP server listening on :\(port)")
    }

    func stop() {
        running = false
        Darwin.close(serverFd)
    }

    private func acceptLoop() {
        while running {
            // ⚠️ Раньше здесь было `accept(serverFd, nil, nil)` — адрес пира, который
            // ядро отдаёт бесплатно, просто выбрасывался. Из-за этого агент не мог
            // отличить запрос телефона по локалке от запроса, пришедшего через
            // Cloudflare (cloudflared стучится в тот же сокет с 127.0.0.1), и вопрос
            // «шёл ли трафик по LAN» был неразрешим по логам.
            var peer = sockaddr_in()
            var len  = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverFd, $0, &len) }
            }
            guard clientFd >= 0 else {
                if !running { break }
                continue
            }
            let peerIP = Self.ipString(peer)
            // Set receive timeout 30s
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            queue.async { self.handleConnection(clientFd, peerIP: peerIP) }
        }
    }

    /// Слушающий сокет — AF_INET, поэтому IPv4 гарантирован.
    private static func ipString(_ addr: sockaddr_in) -> String {
        var a   = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "?" }
        return String(cString: buf)
    }

    private func handleConnection(_ fd: Int32, peerIP: String) {
        defer { Darwin.close(fd) }

        let t0 = DispatchTime.now()
        guard let req = readRequest(fd, peerIP: peerIP) else {
            logger.warning("[REQ] transport=\(Transport.classify(peerIP: peerIP, headers: [:]).rawValue) "
                         + "ip=\(peerIP) status=- error=bad_request_or_timeout")
            return
        }

        // CORS preflight. 6003: reflect an allow-listed Origin only, never "*".
        let cors = CORSPolicy.headers(forOrigin: req.headers["origin"])
        if req.method == "OPTIONS" {
            let resp = HTTPResponse(status: 200, headers: cors, body: .empty)
            _ = sendResponse(fd, resp)
            return                       // префлайты в access-лог не пишем — чистый шум
        }

        guard let router = router else { return }
        var resp = router(req)
        let tRouted = DispatchTime.now()
        // Merge CORS onto whatever the handler returned (handler headers win on key
        // collisions, but CORS keys never collide with handler content headers).
        for (k, v) in cors { resp.headers[k] = v }
        let (sent, declared) = sendResponse(fd, resp)
        let tDone = DispatchTime.now()

        AccessLog.write(req: req, status: resp.status, sent: sent, declared: declared,
                        ttfbMs: Self.ms(t0, tRouted), totalMs: Self.ms(t0, tDone))
    }

    private static func ms(_ a: DispatchTime, _ b: DispatchTime) -> Int {
        Int((b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000)
    }

    // Read HTTP request headers + body
    private func readRequest(_ fd: Int32, peerIP: String) -> HTTPRequest? {
        var headerBytes = [UInt8]()
        var buf         = [UInt8](repeating: 0, count: 4096)

        // Read until \r\n\r\n
        while !hasDoubleNewline(headerBytes) && headerBytes.count < 65536 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            headerBytes.append(contentsOf: buf.prefix(n))
        }

        // Split headers from body
        guard let (headerSection, leftover) = splitHeaders(headerBytes) else { return nil }
        guard let headerStr = String(bytes: headerSection, encoding: .utf8) else { return nil }

        var lines = headerStr.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method    = parts[0]
        let rawTarget = parts[1]
        var headers   = [String: String]()
        for line in lines {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 {
                headers[kv[0].lowercased()] = kv.dropFirst().joined(separator: ": ")
            }
        }

        // Parse path + query
        let (path, query) = parseTarget(rawTarget)

        // Read body if Content-Length present
        var body = Data(leftover)
        if let lenStr = headers["content-length"], let length = Int(lenStr), length > body.count {
            let remaining = length - body.count
            var bodyBuf   = [UInt8](repeating: 0, count: min(remaining, 4 * 1024 * 1024))
            let n = recv(fd, &bodyBuf, bodyBuf.count, MSG_WAITALL)
            if n > 0 { body.append(contentsOf: bodyBuf.prefix(n)) }
        }

        return HTTPRequest(method: method, path: path, queryParams: query,
                           headers: headers, body: body, peerIP: peerIP)
    }

    /// Возвращает (реально отдано байт, обещано Content-Length). Расхождение = клиент
    /// оборвал закачку — ровно тот случай, который выглядел как «играет 2 секунды и
    /// снова буферизуется», и которого раньше в логе не было видно вообще.
    @discardableResult
    private func sendResponse(_ fd: Int32, _ resp: HTTPResponse) -> (sent: Int, declared: Int) {
        // 6003: CORS is applied per-request in handleConnection from an explicit
        // Origin allow-list. No wildcard Access-Control-Allow-Origin here.
        var hdrs = resp.headers
        hdrs["Connection"] = "close"

        switch resp.body {
        case .empty:
            hdrs["Content-Length"] = "0"
            sendHeaders(fd, status: resp.status, headers: hdrs)
            return (0, 0)

        case .data(let data):
            hdrs["Content-Length"] = "\(data.count)"
            sendHeaders(fd, status: resp.status, headers: hdrs)
            return (writeAll(fd, data), data.count)

        case .stream(let closure):
            sendHeaders(fd, status: resp.status, headers: hdrs)
            let declared = hdrs["Content-Length"].flatMap { Int($0) } ?? -1
            return (closure(fd), declared)
        }
    }

    private func sendHeaders(_ fd: Int32, status: Int, headers: [String: String]) {
        var lines = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in headers { lines += "\(k): \(v)\r\n" }
        lines += "\r\n"
        if let data = lines.data(using: .utf8) { writeAll(fd, data) }
    }

    // Write all bytes to socket (handles partial writes). Возвращает записанное —
    // короткая запись означает, что клиент отвалился.
    @discardableResult
    func writeAll(_ fd: Int32, _ data: Data) -> Int {
        socketWriteAll(fd, data)
    }

    // MARK: - Helpers

    private func hasDoubleNewline(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let crlfcrlf: [UInt8] = [13, 10, 13, 10]
        return bytes.windows(ofCount: 4).contains { Array($0) == crlfcrlf }
    }

    private func splitHeaders(_ bytes: [UInt8]) -> ([UInt8], [UInt8])? {
        let crlfcrlf: [UInt8] = [13, 10, 13, 10]
        guard let idx = bytes.indices.first(where: {
            $0 + 4 <= bytes.count && Array(bytes[$0 ..< $0 + 4]) == crlfcrlf
        }) else { return nil }
        return (Array(bytes[..<idx]), Array(bytes[(idx + 4)...]))
    }

    private func parseTarget(_ target: String) -> (String, [String: String]) {
        let comps = target.components(separatedBy: "?")
        let path  = comps[0]
        let query = comps.count > 1 ? parseFormQuery(comps[1]) : [:]
        return (path, query)
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Unknown"
        }
    }
}

// MARK: - Data types

/// Канал, по которому пришёл запрос. Раньше не различался вообще — и это делало
/// вопрос «телефон ходил по локалке или через Cloudflare» неразрешимым по логам.
enum Transport: String {
    case lan      = "LAN"       // прямой коннект из локальной сети (быстрый путь)
    case tunnel   = "TUNNEL"    // через Cloudflare (cloudflared → loopback)
    case relay    = "RELAY"     // реплей облачной команды самим агентом (CloudRelay → loopback)
    case local    = "LOCAL"     // что-то на самой машине (браузер, curl)
    case external = "EXTERNAL"  // прямой коннект с публичного IP — сам по себе тревожный сигнал
    case ui       = "UI"        // in-process вызов из SwiftUI агента

    /// ⚠️ Порядок проверок принципиален, иначе лог начнёт ВРАТЬ.
    ///
    /// `peerIP` из `accept()` — единственный НЕПОДДЕЛЫВАЕМЫЙ сигнал (его ставит ядро).
    /// Поэтому он решает, смотрим ли мы вообще на заголовки: по локалке любой клиент
    /// может прислать себе `cf-ray` и притвориться туннелем. И только внутри loopback —
    /// куда стучатся ТРИ разных источника (cloudflared, CloudRelay, локальный браузер) —
    /// заголовки решают, кто именно из них это был.
    static func classify(peerIP: String, headers: [String: String]) -> Transport {
        guard !peerIP.isEmpty else { return .ui }
        if peerIP != "127.0.0.1" && peerIP != "::1" {
            return isPrivate(peerIP) ? .lan : .external
        }
        // Процессный секрет — подделать из браузера невозможно (см. RelayMarker).
        if headers["x-rimeo-relay-key"] == RelayMarker.key { return .relay }
        if headers["cf-ray"] != nil || headers["cf-connecting-ip"] != nil { return .tunnel }
        return .local
    }

    private static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        if p[0] == 10 { return true }
        if p[0] == 192 && p[1] == 168 { return true }
        if p[0] == 172 && (16...31).contains(p[1]) { return true }
        if p[0] == 169 && p[1] == 254 { return true }   // link-local
        return false
    }
}

/// Блокнот на один запрос. Reference type: заполняется в APIRouter (authGate),
/// читается в handleConnection уже ПОСЛЕ возврата роутера.
final class RequestContext {
    var auth: String = "public"     // psk | jwt | trusted | public | deny:<причина>
}

struct HTTPRequest {
    let method:      String
    let path:        String
    let queryParams: [String: String]
    let headers:     [String: String]
    let body:        Data
    /// True only for requests synthesised in-process by the agent's own SwiftUI
    /// (e.g. the Sign-in / Account / Logs tabs call APIRouter.route directly). The
    /// network path (readRequest) always leaves this false, so socket traffic —
    /// including a same-machine browser drive-by on 127.0.0.1 — is never trusted.
    var trusted: Bool = false
    /// Адрес пира из `accept()`. Пусто ⇒ запрос синтезирован в процессе (UI).
    var peerIP: String = ""
    var ctx: RequestContext = RequestContext()

    var transport: Transport { Transport.classify(peerIP: peerIP, headers: headers) }

    /// Реальный клиент. `cf-connecting-ip` доверяем ТОЛЬКО когда пир — loopback
    /// (то есть заголовок поставил cloudflared, а не сам клиент по локалке).
    var clientIP: String {
        if transport == .tunnel, let real = headers["cf-connecting-ip"], !real.isEmpty { return real }
        return peerIP
    }
}

// MARK: - Access log

enum AccessLog {
    /// Ключи, значения которых НЕЛЬЗЯ писать в лог: он автоматически уезжает в облако
    /// вместе с баг-репортом (`/api/logs` → BugReport). `lan_token` — это PSK агента.
    private static let secretKeys = ["lan_token", "lan_secret", "token", "code", "session", "password"]

    static func write(req: HTTPRequest, status: Int, sent: Int, declared: Int,
                      ttfbMs: Int, totalMs: Int) {
        let t = req.transport
        var f = ["[REQ] transport=\(t.rawValue)", "ip=\(req.clientIP)"]
        if t == .tunnel {
            if req.clientIP != req.peerIP { f.append("via=\(req.peerIP)") }
            if let ray = req.headers["cf-ray"] { f.append("cf_ray=\(ray)") }
        }
        if let rid = req.headers["x-rimeo-req-id"] { f.append("req_id=\(rid)") }
        f.append("method=\(req.method)")
        // req.path не содержит query (её парсит readRequest в queryParams), поэтому
        // собираем сами — иначе не видно, КАКОЙ трек тормозил. Секреты вырезаем:
        // лог автоматически уезжает в облако вместе с баг-репортом.
        f.append("path=\(redact(req.path, params: req.queryParams))")
        if let range = req.headers["range"] { f.append("range=\(range)") }
        f.append("status=\(status)")

        // bytes=X/Y только при НЕДОЛИВЕ — это и есть «клиент оборвал закачку».
        let short = declared > 0 && sent < declared
        f.append(short ? "bytes=\(sent)/\(declared)" : "bytes=\(sent)")
        f.append("ttfb_ms=\(ttfbMs)")          // время внутри роутера (сколько думал агент)
        f.append("ms=\(totalMs)")              // до последнего байта (агент + канал)
        f.append("auth=\(req.ctx.auth)")
        if short { f.append("abort=client") }
        if let ua = req.headers["user-agent"] { f.append("ua=\"\(ua.prefix(60))\"") }

        let line = f.joined(separator: " ")
        if status >= 400 || short { logger.warning(line) } else { logger.info(line) }
    }

    /// Склеивает путь с query, вырезая секреты: `lan_token=<PSK>` → `lan_token=***`.
    /// `path` длинных значений (file location) режем — иначе строка лога раздувается.
    static func redact(_ path: String, params: [String: String]) -> String {
        guard !params.isEmpty else { return path }
        let q = params.keys.sorted().map { k -> String in
            if secretKeys.contains(k.lowercased()) { return "\(k)=***" }
            let v = params[k] ?? ""
            return "\(k)=\(v.count > 80 ? v.prefix(80) + "…" : Substring(v))"
        }.joined(separator: "&")
        return "\(path)?\(q)"
    }
}

/// Пишет всё в сокет, возвращая реально записанное. Короткая запись = клиент отвалился.
@discardableResult
func socketWriteAll(_ fd: Int32, _ data: Data) -> Int {
    data.withUnsafeBytes { ptr -> Int in
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
            if n <= 0 { break }
            offset += n
        }
        return offset
    }
}

struct HTTPResponse {
    var status:  Int
    var headers: [String: String]
    var body:    ResponseBody

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return HTTPResponse(
            status:  status,
            headers: ["Content-Type": "application/json"],
            body:    .data(data)
        )
    }

    static func error(_ msg: String, status: Int = 400) -> HTTPResponse {
        return .json(["detail": msg], status: status)
    }
}

enum ResponseBody {
    case empty
    case data(Data)
    /// Замыкание пишет тело в сокет само и ВОЗВРАЩАЕТ число отданных байт — иначе у
    /// всех `/stream` в access-логе стояло бы `bytes=0`, то есть слепое пятно ровно
    /// там, где болит.
    case stream((Int32) -> Int)
}

enum HTTPServerError: Error {
    case socketFailed
    case bindFailed(String)
    case listenFailed
}

// Sliding window helper (backport-style)
extension Collection {
    func windows(ofCount n: Int) -> [[Element]] {
        guard count >= n else { return [] }
        var result  = [[Element]]()
        var indices = Array(self.indices)
        for i in 0 ..< (indices.count - n + 1) {
            result.append(Array(self[indices[i] ... indices[i + n - 1]]))
        }
        return result
    }
}
