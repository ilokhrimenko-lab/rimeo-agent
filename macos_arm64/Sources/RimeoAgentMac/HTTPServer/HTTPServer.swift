import Foundation
import Darwin

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
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                if !running { break }
                continue
            }
            // Set receive timeout 30s
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            queue.async { self.handleConnection(clientFd) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }

        guard let req = readRequest(fd) else { return }

        // CORS preflight
        if req.method == "OPTIONS" {
            let resp = HTTPResponse(status: 200, headers: corsHeaders(), body: .empty)
            sendResponse(fd, resp)
            return
        }

        guard let router = router else { return }
        let resp = router(req)
        sendResponse(fd, resp)
    }

    // Read HTTP request headers + body
    private func readRequest(_ fd: Int32) -> HTTPRequest? {
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
                           headers: headers, body: body)
    }

    private func sendResponse(_ fd: Int32, _ resp: HTTPResponse) {
        var hdrs = resp.headers
        hdrs["Access-Control-Allow-Origin"]  = "*"
        hdrs["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        hdrs["Access-Control-Allow-Headers"] = "*"
        hdrs["Connection"]                   = "close"

        switch resp.body {
        case .empty:
            hdrs["Content-Length"] = "0"
            sendHeaders(fd, status: resp.status, headers: hdrs)

        case .data(let data):
            hdrs["Content-Length"] = "\(data.count)"
            sendHeaders(fd, status: resp.status, headers: hdrs)
            writeAll(fd, data)

        case .stream(let closure):
            sendHeaders(fd, status: resp.status, headers: hdrs)
            closure(fd)
        }
    }

    private func sendHeaders(_ fd: Int32, status: Int, headers: [String: String]) {
        var lines = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (k, v) in headers { lines += "\(k): \(v)\r\n" }
        lines += "\r\n"
        if let data = lines.data(using: .utf8) { writeAll(fd, data) }
    }

    // Write all bytes to socket (handles partial writes)
    func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { ptr in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
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
        var query = [String: String]()
        if comps.count > 1 {
            for pair in comps[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let k = kv[0].removingPercentEncoding ?? kv[0]
                    let v = kv[1].removingPercentEncoding ?? kv[1]
                    query[k] = v
                } else if kv.count == 1 {
                    query[kv[0]] = ""
                }
            }
        }
        return (path, query)
    }

    private func corsHeaders() -> [String: String] {
        ["Access-Control-Allow-Origin":  "*",
         "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
         "Access-Control-Allow-Headers": "*"]
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

struct HTTPRequest {
    let method:      String
    let path:        String
    let queryParams: [String: String]
    let headers:     [String: String]
    let body:        Data
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
    case stream((Int32) -> Void)
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
