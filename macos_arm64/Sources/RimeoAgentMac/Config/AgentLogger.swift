import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0, info = 1, warn = 2, error = 3
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// Файловый лог агента.
///
/// ⚠️ ГРАБЛИ, СТОИВШИЕ ПОЛДНЯ АРХЕОЛОГИИ (13.07.2026):
/// Прошлая версия держала кольцевой буфер на 500 строк и **переписывала весь файл
/// целиком** (`lines.joined().write(to:atomically:)`) на КАЖДУЮ строку лога. Три
/// последствия, каждое из которых кусалось:
///   1. Глубина памяти ~17 минут (91% строк съедал debug-спам relay-поллинга) —
///      расследовать вчерашний инцидент было физически нечем.
///   2. Рестарт агента затирал улики о рестарте агента.
///   3. Атомарная запись = temp-файл + rename на каждую строку. Во время стрима
///      (range-шторм AVPlayer) это десятки лишних записей на диск в секунду.
///
/// Теперь: append через FileHandle + ротация по размеру. Файл переживает рестарт,
/// история не теряется, диск не насилуется.
final class AgentLogger {
    static let shared = AgentLogger()

    // MARK: - Диск

    private let queue       = DispatchQueue(label: "rimeo.logger", qos: .utility)
    private var handle:     FileHandle?
    private var fileBytes   = 0                // ведём сами, чтобы не звать stat на каждой строке
    private let maxBytes    = 5 * 1024 * 1024  // 5 МБ на файл
    private let generations = 3                // agent.log + .1 + .2 → максимум 15 МБ
    private let logURL:     URL

    // MARK: - Память (только для UI и report_bug — от файла отвязано)

    /// Отдельный NSLock, а НЕ `queue.sync`: ротация живёт в той же serial-очереди,
    /// и `lastLines()` из UI-потока мог бы с ней сцепиться в дедлок.
    private let ringLock = NSLock()
    private var ring: [String] = []
    private let ringCap = 1000                 // APIRouter просит 800 — раньше физически не влезало

    /// Порог отсечки. debug гасится по умолчанию: relay-поллинг генерит его каждые
    /// пару секунд и раньше вытеснял из лога всё полезное.
    /// Включить: `defaults write app.rimeo.agent rimeo_verbose_logging -bool true` + рестарт.
    var minLevel: LogLevel = UserDefaults.standard.bool(forKey: "rimeo_verbose_logging") ? .debug : .info

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        logURL = AppConfig.shared.logFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
        fileBytes = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) .flatMap { $0 } ?? 0
    }

    // MARK: - Запись

    func log(_ level: LogLevel, _ msg: String) {
        guard level >= minLevel else { return }          // отсечка ДО форматирования
        let line = "\(formatter.string(from: Date())) [\(level.tag)] \(msg)"
        queue.async {
            print(line)
            self.ringLock.lock()
            self.ring.append(line)
            if self.ring.count > self.ringCap {
                self.ring.removeFirst(self.ring.count - self.ringCap)
            }
            self.ringLock.unlock()

            guard let data = (line + "\n").data(using: .utf8) else { return }
            self.handle?.write(data)                     // append, без переписи файла
            self.fileBytes += data.count
            self.rotateIfNeeded()
        }
    }

    func info(_ msg: String)    { log(.info,  msg) }
    func warning(_ msg: String) { log(.warn,  msg) }
    func error(_ msg: String)   { log(.error, msg) }
    func debug(_ msg: String)   { log(.debug, msg) }

    /// ⚠️ Вызывается ТОЛЬКО из `queue`. Внутри нельзя звать `logger` — это рекурсия
    /// и дедлок на той же serial-очереди. Все ошибки уходят в stderr.
    private func rotateIfNeeded() {
        guard fileBytes >= maxBytes else { return }
        let fm = FileManager.default
        handle?.closeFile()
        handle = nil

        let base = logURL.path
        // agent.log.2 (самый старый) выбрасываем, остальные сдвигаем вниз.
        try? fm.removeItem(atPath: "\(base).\(generations - 1)")
        var gen = generations - 1
        while gen >= 1 {
            let from = gen == 1 ? base : "\(base).\(gen - 1)"
            let to   = "\(base).\(gen)"
            if fm.fileExists(atPath: from) {
                do { try fm.moveItem(atPath: from, toPath: to) }
                catch { fputs("rimeo-logger: rotate \(from) → \(to) failed: \(error)\n", stderr) }
            }
            gen -= 1
        }

        fm.createFile(atPath: base, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        fileBytes = 0
        let head = "\(formatter.string(from: Date())) [INFO] [ROTATE] предыдущий файл → agent.log.1\n"
        if let d = head.data(using: .utf8) {
            handle?.write(d)
            fileBytes += d.count
        }
    }

    // MARK: - Чтение

    /// Хвост из памяти — дёшево, для UI и «Report a problem».
    func lastLines(_ n: Int) -> String {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring.suffix(n).joined(separator: "\n")
    }

    /// Хвост ФАЙЛА по байтам (переживает рестарт, в отличие от ring).
    /// Читается seek'ом с конца — файл целиком в RAM не поднимается.
    func tail(bytes n: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()).map { Int($0) } ?? 0
        let from = max(0, size - n)
        try? fh.seek(toOffset: UInt64(from))
        let data = (try? fh.readToEnd()) ?? Data()
        var text = String(data: data, encoding: .utf8) ?? ""
        // Срез мог попасть в середину строки — выбрасываем огрызок.
        if from > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    // MARK: - Жизненный цикл (видимость рестартов)

    private static let kPID     = "rimeo_run_pid"
    private static let kStarted = "rimeo_run_started_at"
    private static let kSeen    = "rimeo_run_last_seen"
    private static let kClean   = "rimeo_run_clean"

    private var heartbeat: DispatchSourceTimer?

    /// Пишет строку старта — с данными о ПРЕДЫДУЩЕМ запуске. Именно она отвечает на
    /// «агент падал или его перезапустили руками»: `exit=unclean` = не было
    /// applicationWillTerminate, то есть процесс убит/упал.
    func boot() {
        let d = UserDefaults.standard
        var prev = "prev=(нет данных)"
        if let started = d.object(forKey: Self.kStarted) as? Date {
            let pid   = d.integer(forKey: Self.kPID)
            let seen  = (d.object(forKey: Self.kSeen) as? Date) ?? started
            let clean = d.bool(forKey: Self.kClean)
            let up    = Int(seen.timeIntervalSince(started))
            prev = "prev=(pid=\(pid) started=\(formatter.string(from: started)) "
                 + "uptime=\(up / 3600)h\((up % 3600) / 60)m last_seen=\(formatter.string(from: seen)) "
                 + "exit=\(clean ? "clean" : "unclean"))"
        }
        let cfg = AppConfig.shared
        d.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: Self.kPID)
        d.set(Date(), forKey: Self.kStarted)
        d.set(Date(), forKey: Self.kSeen)
        d.set(false,  forKey: Self.kClean)

        info("[BOOT] ===== AGENT START pid=\(ProcessInfo.processInfo.processIdentifier) "
           + "build=\(cfg.buildNumber) port=\(cfg.port) log_max=5MB gens=\(generations) \(prev) =====")

        // last_seen раз в минуту → uptime упавшего процесса восстановим с точностью ~1 мин.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { UserDefaults.standard.set(Date(), forKey: Self.kSeen) }
        t.resume()
        heartbeat = t
    }

    /// Зовётся из applicationWillTerminate — помечает выход как штатный.
    func markCleanExit() {
        let d = UserDefaults.standard
        d.set(Date(), forKey: Self.kSeen)
        d.set(true,   forKey: Self.kClean)
        info("[BOOT] ===== AGENT STOP pid=\(ProcessInfo.processInfo.processIdentifier) (clean) =====")
        queue.sync { }              // дождаться слива очереди — иначе строка не долетит до диска
    }
}

let logger = AgentLogger.shared
