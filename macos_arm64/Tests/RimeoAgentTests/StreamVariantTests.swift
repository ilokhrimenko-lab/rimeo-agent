import XCTest
@testable import RimeoAgent

/// Правило «в каком виде отдавать файл» — то самое, что привело к баг-репорту #83:
/// один и тот же трек уезжал в iOS то оригинальным AIFF (через туннель, где прокси
/// дописывает `src=ios`), то WAV-конверсией (по локальной сети, где iOS раньше `src`
/// не слал). Префиксный кеш плеера склеил голову одного представления с хвостом
/// другого — и это игралось как громкий белый шум.
///
/// Ключевое свойство, которое тут пришпилено: при ОДИНАКОВЫХ параметрах запроса ответ
/// не зависит ни от чего внешнего — маршрут, порядок параметров и предыдущие вызовы на
/// него не влияют.
final class StreamVariantTests: XCTestCase {

    private let threshold = 2000

    private func decide(ext: String = "aiff", raw: Bool = false, fmt: String = "",
                        src: String = "unknown", bitrate: Int = 0) -> StreamVariant {
        StreamVariant.decide(ext: ext, raw: raw, fmt: fmt, src: src,
                             bitrate: bitrate, hiResThreshold: threshold)
    }

    // MARK: - AIFF: ветка, на которой всё и разъехалось

    func testAIFFForIOSStaysOriginal() {
        XCTAssertEqual(decide(ext: "aiff", src: "ios"), .original)
        XCTAssertEqual(decide(ext: "aif", src: "ios"), .original)
    }

    func testAIFFForWebIsConverted() {
        XCTAssertEqual(decide(ext: "aiff", src: "web"), .wav)
    }

    /// Клиент, не назвавший себя, исторически трактуется как веб — иначе старый веб-плеер
    /// получил бы AIFF, который он не декодирует.
    func testAIFFForUnknownClientIsConverted() {
        XCTAssertEqual(decide(ext: "aiff", src: "unknown"), .wav)
        XCTAssertEqual(decide(ext: "aiff", src: ""), .wav)
    }

    /// Самое важное: iOS, назвавшийся одинаково, получает ОДНО представление — независимо
    /// от того, пришёл он по локальной сети или через туннель. Раньше это и разъезжалось.
    func testSameClientGetsSameVariantRegardlessOfRoute() {
        let lan = decide(ext: "aiff", src: "ios")
        let tunnel = decide(ext: "aiff", src: "ios")
        XCTAssertEqual(lan, tunnel)
        XCTAssertEqual(lan, .original)
    }

    // MARK: - Явный fmt приоритетнее «кто спросил»

    func testExplicitWavBeatsIOSHeuristic() {
        XCTAssertEqual(decide(ext: "aiff", fmt: "wav", src: "ios"), .wav)
    }

    func testExplicitOriginalBeatsWebHeuristic() {
        XCTAssertEqual(decide(ext: "aiff", fmt: "original", src: "web"), .original)
    }

    func testExplicitOriginalBeatsHiRes() {
        XCTAssertEqual(decide(ext: "wav", fmt: "original", src: "web", bitrate: 4608), .original)
    }

    /// `fmt=wav` осмыслен только для AIFF: на прочих форматах он ничего не меняет — так же
    /// ведёт себя Windows-агент (см. PARITY.md), и это часть общего контракта.
    func testExplicitWavIsNoOpForNonAIFF() {
        XCTAssertEqual(decide(ext: "mp3", fmt: "wav", src: "web"), .original)
        XCTAssertEqual(decide(ext: "wav", fmt: "wav", src: "web"), .original)
    }

    // MARK: - raw=1 (скачивание/офлайн) — всегда байт-в-байт

    func testRawAlwaysWinsOverEverything() {
        XCTAssertEqual(decide(ext: "aiff", raw: true, src: "web"), .original)
        XCTAssertEqual(decide(ext: "aiff", raw: true, fmt: "wav", src: "web"), .original)
        XCTAssertEqual(decide(ext: "wav", raw: true, src: "ios", bitrate: 4608), .original)
    }

    // MARK: - Hi-res: одинаково для всех клиентов

    func testHiResIsDownConvertedForEveryClient() {
        XCTAssertEqual(decide(ext: "wav", src: "ios", bitrate: 4608), .wav16)
        XCTAssertEqual(decide(ext: "wav", src: "web", bitrate: 4608), .wav16)
        // 24-битный AIFF тоже уходит в 16 бит, а не в обычную AIFF→WAV-ветку.
        XCTAssertEqual(decide(ext: "aiff", src: "ios", bitrate: 2116), .wav16)
    }

    func testBitrateExactlyAtThresholdIsNotHiRes() {
        XCTAssertEqual(decide(ext: "wav", src: "ios", bitrate: threshold), .original)
    }

    /// Неизвестный битрейт (0) не должен внезапно включать конверсию: иначе представление
    /// менялось бы вместе с состоянием парсера библиотеки, а кеш клиента — протухал.
    func testUnknownBitrateIsNotHiRes() {
        XCTAssertEqual(decide(ext: "wav", src: "ios", bitrate: 0), .original)
        XCTAssertEqual(decide(ext: "mp3", src: "web", bitrate: 0), .original)
    }

    // MARK: - Обычные форматы не трогаем

    func testRegularFormatsAreServedAsIs() {
        for ext in ["mp3", "wav", "flac", "m4a"] {
            XCTAssertEqual(decide(ext: ext, src: "ios"), .original, "ext=\(ext)")
            XCTAssertEqual(decide(ext: ext, src: "web"), .original, "ext=\(ext)")
        }
    }

    /// Заголовок `X-Rimeo-Variant` — часть контракта с клиентским кешем: значения не
    /// переименовывать, iOS сверяет их со своей записью.
    func testWireValuesAreStable() {
        XCTAssertEqual(StreamVariant.original.rawValue, "original")
        XCTAssertEqual(StreamVariant.wav.rawValue, "wav")
        XCTAssertEqual(StreamVariant.wav16.rawValue, "wav16")
    }
}
