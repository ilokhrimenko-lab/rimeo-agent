import Foundation

// Битые треки: запись в библиотеке есть, файла на диске нет. На реальной библиотеке это
// 150 треков из 2280 (6.6%) — импорт из медиатеки iTunes 2020 года ("/Contents/…"), пути
// со старым юзернеймом ("/Users/ilya/…", такого пользователя больше не существует) и записи
// вида "soundcloud:tracks:123", которые вообще не файлы.
//
// ПОЧЕМУ ЭТО ВАЖНО ИМЕННО ДЛЯ РЕКОМЕНДАЦИЙ. Битый трек НИКОГДА не игрался — по определению,
// играть-то нечего. Значит для квоты открытий (она берёт именно непроигранные треки) он
// выглядит идеальным кандидатом: 131 из 150 битых треков непроигранные. Без этого гейта
// блок «что добавить» начал бы подсовывать треки, которых физически нет на диске — тот самый
// «случайный мусор», на который и жаловался пользователь.
//
// ЦЕНА ПРОВЕРКИ. stat() на 2280 треков в КАЖДОМ запросе — недопустимо. Поэтому множество
// недоступных id считается один раз на версию библиотеки и кэшируется.
final class TrackAvailability {
    static let shared = TrackAvailability()
    private init() {}

    private let lock = NSLock()
    private var version = ""
    private var unavailable = Set<String>()

    /// Ключ кэша. Кроме версии библиотеки в него входит СПИСОК СМОНТИРОВАННЫХ ТОМОВ:
    /// отключённый внешний диск делает свои треки временно недоступными, но не мёртвыми
    /// навсегда. Воткнули диск обратно — ключ поменялся, множество пересчиталось, треки
    /// вернулись в выдачу. Без этого они «умерли» бы до следующего изменения библиотеки.
    private static func versionKey(_ lib: LibraryData) -> String {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?
            .sorted().joined(separator: ",") ?? ""
        return "\(lib.xml_date)|\(lib.tracks.count)|\(volumes)"
    }

    /// id треков, которые сейчас нечем играть. Тяжёлый проход — только при смене ключа.
    func unavailableIDs(in lib: LibraryData) -> Set<String> {
        let key = TrackAvailability.versionKey(lib)
        lock.lock(); defer { lock.unlock() }
        if key == version { return unavailable }

        let fm = FileManager.default
        var dead = Set<String>()
        for t in lib.tracks where !TrackAvailability.isPlayable(t.location, fm: fm) {
            dead.insert(t.id)
        }
        version = key
        unavailable = dead
        return dead
    }

    func invalidate() {
        lock.lock(); version = ""; unavailable = []; lock.unlock()
    }

    /// Есть ли что играть по этому пути.
    ///
    /// Не-абсолютный путь отбрасываем сразу и НЕ трогаем диск: "soundcloud:tracks:123" — это
    /// не файл, а ссылка на стрим, которого у агента нет. Точно так же отсекаются относительные
    /// огрызки, оставшиеся от старых импортов.
    static func isPlayable(_ location: String, fm: FileManager = .default) -> Bool {
        let path = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        return fm.fileExists(atPath: path)
    }
}
