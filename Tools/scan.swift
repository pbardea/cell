// Lists advertising BLE devices. Prints the cached name macOS holds alongside
// the name actually being broadcast -- they differ after you rename or forget a
// device, which is a common source of "I can't find my keyboard in the list".
//
//   swiftc -O Tools/scan.swift -o scan && ./scan

import Foundation
import CoreBluetooth

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    private var seen = Set<UUID>()

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else {
            print("bluetooth unavailable (state \(manager.state.rawValue))")
            return
        }
        print("scanning 10s...\n")
        manager.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard seen.insert(p.identifier).inserted else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard p.name != nil || advertised != nil else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? "-"
        print("cached=\(p.name ?? "nil")  advertised=\(advertised ?? "(none)")")
        print("    rssi=\(rssi)  services=\(services)  id=\(p.identifier)")
    }
}

let scanner = Scanner()
scanner.central = CBCentralManager(delegate: scanner, queue: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
RunLoop.main.run()
