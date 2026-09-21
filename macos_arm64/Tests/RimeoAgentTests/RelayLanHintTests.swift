import XCTest
@testable import RimeoAgent

/// LAN-адрес агента по heartbeat релея (`&lan=ip:port`). Облако (v1.34.3+) обновляет по нему
/// подсказку lan_ip для телефона; раньше она писалась только при логине и протухала.
final class RelayLanHintTests: XCTestCase {
    func test_regularAddress() {
        XCTAssertEqual(CloudRelay.lanHint(ip: "192.168.1.46", port: 8000), "192.168.1.46:8000")
        XCTAssertEqual(CloudRelay.lanHint(ip: " 10.0.0.2 ", port: 8042), "10.0.0.2:8042")
    }
    func test_uselessAddresses_areNotSent() {
        XCTAssertNil(CloudRelay.lanHint(ip: "127.0.0.1", port: 8000), "нет сети → getLocalIP отдаёт loopback")
        XCTAssertNil(CloudRelay.lanHint(ip: "0.0.0.0", port: 8000))
        XCTAssertNil(CloudRelay.lanHint(ip: "", port: 8000))
        XCTAssertNil(CloudRelay.lanHint(ip: "192.168.1.5", port: 0))
    }
    func test_noScheme_WAFSafe() {
        XCTAssertFalse((CloudRelay.lanHint(ip: "192.168.1.5", port: 8000) ?? "").contains("http"),
                       "`http://` в query — триггер WAF, а его 403 агент считает отказом токена")
    }
}
