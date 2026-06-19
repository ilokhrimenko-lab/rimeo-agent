//
//  BonjourAdvertiser.swift
//  RimeoAgentMac
//
//  M4: advertises the agent on the local network as `_rimeo._tcp` so the iOS app's
//  LANDiscovery (NWBrowser) can find it and resolve a live IP:port — surviving DHCP
//  changes. TXT carries agent_id + protocol version. We advertise an already-open
//  port (the HTTP server's), so NetService (publishes a record for an existing
//  socket) is the right tool rather than NWListener.
//

import Foundation

final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    static let shared = BonjourAdvertiser()

    private var service: NetService?

    /// Begin advertising `_rimeo._tcp` on the given port. Safe to call repeatedly.
    func start(port: UInt16, agentID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopOnMain()
            let svc = NetService(domain: "local.", type: "_rimeo._tcp.",
                                 name: "", port: Int32(port))
            svc.delegate = self
            let txt: [String: Data] = [
                "agent_id": Data(agentID.utf8),
                "v":        Data("2".utf8),
            ]
            svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
            svc.schedule(in: RunLoop.main, forMode: .common)
            svc.publish()
            self.service = svc
            AgentLogger.shared.info("Bonjour: advertising _rimeo._tcp on :\(port)")
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in self?.stopOnMain() }
    }

    private func stopOnMain() {
        service?.stop()
        service = nil
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        AgentLogger.shared.info("Bonjour: published as \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        AgentLogger.shared.error("Bonjour: publish failed \(errorDict)")
    }
}
