import AppKit
import CoreBluetooth
import ServiceManagement

// MARK: - Constants

private let basUUID = CBUUID(string: "180F")
private let hidUUID = CBUUID(string: "1812")
private let batteryLevelUUID = CBUUID(string: "2A19")
private let presentationFormatUUID = CBUUID(string: "2904")

private enum Key {
    static let deviceID = "deviceIdentifier"
    static let swapSides = "swapSides"
    static let hideIcon = "hideIcon"
}

/// Bluetooth SIG "GATT Characteristic Presentation Format" description values.
/// ZMK tags each proxied battery service with one of these so hosts can tell
/// the halves apart. Anything unrecognised falls back to discovery order.
private let formatDescriptions: [UInt16: String] = [
    0x0001: "First", 0x0002: "Second", 0x0003: "Third", 0x0004: "Fourth",
    0x0005: "Fifth", 0x0006: "Sixth", 0x0007: "Seventh", 0x0008: "Eighth",
    0x0100: "Front", 0x0101: "Back", 0x0102: "Top", 0x0103: "Bottom",
    0x0104: "Upper", 0x0105: "Lower", 0x0106: "Main", 0x0107: "Backup",
    0x0108: "Auxiliary", 0x0109: "Supplementary", 0x010A: "Flash",
    0x010B: "Inside", 0x010C: "Outside", 0x010D: "Left", 0x010E: "Right",
    0x010F: "Internal", 0x0110: "External",
]

// MARK: - Model

/// One battery reading. A split keyboard running the proxy config reports one
/// of these per half, in a stable discovery order.
private struct Reading {
    let order: Int
    var hint: String?
    var level: Int?
    var updated: Date?
}

// MARK: - Controller

final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var readings: [ObjectIdentifier: Reading] = [:]
    private var candidates: [CBPeripheral] = []
    private var statusItem: NSStatusItem!
    private var reconnectScheduled = false

    private var swapSides: Bool {
        get { UserDefaults.standard.bool(forKey: Key.swapSides) }
        set { UserDefaults.standard.set(newValue, forKey: Key.swapSides); render() }
    }

    /// Defaults to false, so the glyph shows unless it is turned off.
    private var hideIcon: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hideIcon) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hideIcon); render() }
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        render()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Discovery

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn: connectToKeyboard()
        default: readings.removeAll(); render()
        }
    }

    private func connectToKeyboard() {
        guard central.state == .poweredOn else { return }

        // Already-paired HID keyboards stay connected to the OS, so there is no
        // need to scan -- we can retrieve them and read GATT directly.
        candidates = central.retrieveConnectedPeripherals(withServices: [basUUID, hidUUID])
            .sorted { ($0.name ?? "") < ($1.name ?? "") }

        // Mice and headphones expose a battery service too, so never guess
        // between several unknown devices -- let the menu picker decide.
        let stored = UserDefaults.standard.string(forKey: Key.deviceID)
        let chosen = candidates.first { $0.identifier.uuidString == stored }
            ?? candidates.first { p in
                ["sofle", "ergomech"].contains { (p.name ?? "").localizedCaseInsensitiveContains($0) }
            }
            ?? (candidates.count == 1 ? candidates.first : nil)

        guard let chosen else { render(); return }
        // A guess is never written to disk -- otherwise picking the only
        // candidate around (a mouse, while the keyboard is off) would stick
        // permanently. Only an explicit choice from the menu is remembered.
        select(chosen, remember: false)
    }

    private func select(_ peripheral: CBPeripheral, remember: Bool) {
        if let current = keyboard, current.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(current)
        }
        if remember {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Key.deviceID)
        }
        keyboard = peripheral
        readings.removeAll()
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        render()
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([basUUID])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        scheduleReconnect()
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        readings.removeAll()
        render()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.reconnectScheduled = false
            self?.connectToKeyboard()
        }
    }

    // MARK: Reading

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).filter { $0.uuid == basUUID }
        for service in services {
            peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
        }
        if services.isEmpty { render() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevelUUID {
            readings[ObjectIdentifier(characteristic)] = Reading(order: readings.count)
            peripheral.readValue(for: characteristic)
            peripheral.discoverDescriptors(for: characteristic)
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        render()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let byte = characteristic.value?.first else { return }
        let id = ObjectIdentifier(characteristic)
        readings[id, default: Reading(order: readings.count)].level = Int(byte)
        readings[id]?.updated = Date()
        render()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        for descriptor in characteristic.descriptors ?? []
        where descriptor.uuid == presentationFormatUUID {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        guard descriptor.uuid == presentationFormatUUID,
              let characteristic = descriptor.characteristic,
              let data = descriptor.value as? Data, data.count >= 7 else { return }
        // Presentation format: [format, exponent, unit(2), namespace, description(2)]
        let code = UInt16(data[5]) | (UInt16(data[6]) << 8)
        readings[ObjectIdentifier(characteristic)]?.hint = formatDescriptions[code]
        render()
    }

    // MARK: Presentation

    /// ZMK tags the central's own battery "Main" and each proxied peripheral
    /// "Auxiliary", so prefer that over discovery order -- the central then
    /// always sorts first regardless of the order services come back in.
    private func rank(_ reading: Reading) -> Int {
        switch reading.hint {
        case "Main": return -2
        case "Auxiliary": return -1
        default: return reading.order
        }
    }

    private func sortedReadings() -> [Reading] {
        let ordered = readings.values.sorted {
            rank($0) == rank($1) ? $0.order < $1.order : rank($0) < rank($1)
        }
        guard ordered.count > 1, swapSides else { return ordered }
        return ordered.reversed()
    }

    /// Names a reading. With two or more halves the side matters more than the
    /// GATT hint, so order (optionally swapped) wins and the hint is a suffix.
    private func label(_ reading: Reading, index: Int, total: Int) -> String {
        guard total > 1 else { return reading.hint ?? "Battery" }
        let side = index == 0 ? "Left" : (index == 1 ? "Right" : "Half \(index + 1)")
        if let hint = reading.hint,
           !["Main", "Auxiliary", "First", "Second"].contains(hint) {
            return "\(side) (\(hint))"
        }
        return side
    }

    private func render() {
        let items = sortedReadings()
        guard let button = statusItem.button else { rebuildMenu(items); return }

        let lowest = items.compactMap(\.level).min()
        // The menu bar is crowded real estate: no percent signs, a hairline
        // separator between halves, and a slightly tighter face than body text.
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.image = hideIcon ? nil : batterySymbol(for: lowest)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        // The hair space sets the glyph off from the digits; without a glyph it
        // would just be a dent in the menu bar spacing.
        let gap = hideIcon ? "" : "\u{2009}"
        button.title = items.isEmpty
            ? gap + "--"
            : gap + items.map { $0.level.map(String.init) ?? "--" }
                         .joined(separator: "\u{2009}·\u{2009}")
        // Tinting the button colours the template symbol and the text together.
        button.contentTintColor = (lowest ?? 100) <= 20 ? .systemRed : nil

        rebuildMenu(items)
    }

    /// The system battery glyph matching the charge, so the menu bar item looks
    /// like every other macOS indicator. SF Symbol names gained a "percent"
    /// suffix in macOS 14, so try the modern name first and fall back.
    private func batterySymbol(for level: Int?) -> NSImage? {
        let names: [String]
        switch level {
        case .none:                       names = ["battery.0percent", "battery.0"]
        case .some(let l) where l <= 10:  names = ["battery.0percent", "battery.0"]
        case .some(let l) where l <= 35:  names = ["battery.25percent", "battery.25"]
        case .some(let l) where l <= 60:  names = ["battery.50percent", "battery.50"]
        case .some(let l) where l <= 85:  names = ["battery.75percent", "battery.75"]
        default:                          names = ["battery.100percent", "battery.100"]
        }
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Battery") {
                image.isTemplate = true
                return image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            }
        }
        return nil
    }

    private func rebuildMenu(_ items: [Reading]) {
        let menu = NSMenu()
        let unchosen = keyboard == nil && !candidates.isEmpty
        menu.addItem(header(keyboard?.name ?? (unchosen ? "Choose your keyboard"
                                                       : "No keyboard found")))

        if items.isEmpty {
            let hint: String
            if central?.state != .poweredOn {
                hint = "Bluetooth unavailable"
            } else if unchosen {
                hint = "Pick it under “Keyboard” below"
            } else {
                hint = "Waiting for battery service…"
            }
            menu.addItem(disabled(hint))
        } else {
            for (index, reading) in items.enumerated() {
                let title = label(reading, index: index, total: items.count)
                let value = reading.level.map { "\($0)%" } ?? "--"
                menu.addItem(disabled("\(title): \(value)\(bar(reading.level))"))
            }
            if items.count == 1 {
                menu.addItem(.separator())
                menu.addItem(disabled("Only one half reported."))
                menu.addItem(disabled("Enable the ZMK battery proxy for both."))
            }
        }

        menu.addItem(.separator())
        if let newest = items.compactMap(\.updated).max() {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            menu.addItem(disabled("Updated \(formatter.string(from: newest))"))
        }

        menu.addItem(item("Refresh", #selector(refresh)))

        if items.count > 1 {
            let swap = item("Swap Left / Right", #selector(toggleSwap))
            swap.state = swapSides ? .on : .off
            menu.addItem(swap)
        }

        let icon = item("Hide Battery Icon", #selector(toggleIcon))
        icon.state = hideIcon ? .on : .off
        menu.addItem(icon)

        if !candidates.isEmpty {
            let picker = NSMenu()
            for peripheral in candidates {
                let entry = NSMenuItem(title: peripheral.name ?? peripheral.identifier.uuidString,
                                       action: #selector(pickDevice(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = peripheral
                entry.state = peripheral.identifier == keyboard?.identifier ? .on : .off
                picker.addItem(entry)
            }
            let parent = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: "")
            parent.submenu = picker
            menu.addItem(parent)
        }

        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func bar(_ level: Int?) -> String {
        guard let level else { return "" }
        let filled = max(0, min(10, Int((Double(level) / 10).rounded())))
        return "   " + String(repeating: "▮", count: filled)
            + String(repeating: "▯", count: 10 - filled)
    }

    private func header(_ text: String) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        entry.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
        return entry
    }

    private func disabled(_ text: String) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    // MARK: Actions

    @objc private func refresh() {
        guard let keyboard else { connectToKeyboard(); return }
        if keyboard.state == .connected {
            for service in (keyboard.services ?? []) where service.uuid == basUUID {
                for characteristic in service.characteristics ?? []
                where characteristic.uuid == batteryLevelUUID {
                    keyboard.readValue(for: characteristic)
                }
            }
        } else {
            connectToKeyboard()
        }
    }

    @objc private func toggleSwap() { swapSides.toggle() }

    @objc private func toggleIcon() { hideIcon.toggle() }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let peripheral = sender.representedObject as? CBPeripheral else { return }
        select(peripheral, remember: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        render()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let monitor = BatteryMonitor()
monitor.start()
app.run()
