// Dumps a connected BLE device's services, battery characteristics and their
// descriptors. Useful when checking whether firmware actually exposes a second
// battery service.
//
//   swiftc -O Tools/probe.swift -o probe
//   ./probe              # first connected device with a battery/HID service
//   ./probe sofle        # first whose name contains "sofle" (case-insensitive)

import Foundation
import CoreBluetooth

let bas = CBUUID(string: "180F")
let hid = CBUUID(string: "1812")
let batteryLevel = CBUUID(string: "2A19")
let nameFilter = CommandLine.arguments.dropFirst().first

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        print("bluetooth state: \(manager.state.rawValue) (5 == poweredOn)")
        guard manager.state == .poweredOn else { return }

        let connected = manager.retrieveConnectedPeripherals(withServices: [bas, hid])
        print("connected devices (\(connected.count)):")
        for device in connected { print("  - \(device.name ?? "(unnamed)")  \(device.identifier)") }

        let target = nameFilter.flatMap { filter in
            connected.first { ($0.name ?? "").localizedCaseInsensitiveContains(filter) }
        } ?? connected.first

        guard let target else { print("nothing to probe"); exit(1) }
        print("\nprobing \(target.name ?? "(unnamed)")...")
        target.delegate = self
        manager.connect(target, options: nil)
    }

    func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    func centralManager(_ m: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("failed to connect: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("discovery failed: \(error)"); exit(1) }
        let services = p.services ?? []
        print("services (\(services.count)):")
        for service in services { print("  \(service.uuid)") }
        for service in services where service.uuid == bas {
            p.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for characteristic in s.characteristics ?? [] where characteristic.uuid == batteryLevel {
            p.readValue(for: characteristic)
            p.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor c: CBCharacteristic, error: Error?) {
        for descriptor in c.descriptors ?? [] { p.readValue(for: descriptor) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let level = c.value?.first else { return }
        print(">>> battery = \(level)%   (service \(c.service?.uuid.uuidString ?? "?"))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        if let data = d.value as? Data {
            // Presentation format: [format, exponent, unit(2), namespace, description(2)]
            // 0x0106 "main" tags a central's own battery, 0x0108 "auxiliary" a proxied one.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            print("    \(d.uuid) = 0x\(hex)")
        } else if let text = d.value {
            print("    \(d.uuid) = \(text)")
        }
    }
}

let probe = Probe()
probe.central = CBCentralManager(delegate: probe, queue: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("-- done --"); exit(0) }
RunLoop.main.run()
