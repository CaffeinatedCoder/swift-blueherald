import BlueHeraldCore
import Foundation
import Testing

@Suite("BLEUUID")
struct BLEUUIDTests {
    @Test(
        "short, prefixed and long spellings of a SIG UUID are equal",
        arguments: [
            "2A19", "2a19", "0x2A19", " 2a19 ", "00002A19", "00002a19-0000-1000-8000-00805f9b34fb", "00002A1900001000800000805F9B34FB",
        ])
    func sigSpellings(text: String) throws {
        let uuid = try #require(BLEUUID(text))
        #expect(uuid == BLEUUID(0x2A19))
        #expect(uuid.shortValue == 0x2A19)
        #expect(uuid.description == "2A19")
    }

    @Test("vendor UUIDs keep the dashed form")
    func vendorUUID() throws {
        let uuid = try #require(BLEUUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e"))
        #expect(uuid.shortValue == nil)
        #expect(uuid.description == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(BLEUUID(uuid.uuid) == uuid)
    }

    @Test("32-bit SIG UUIDs print as eight digits")
    func thirtyTwoBit() throws {
        let uuid = try #require(BLEUUID("1234ABCD"))
        #expect(uuid.description == "1234ABCD")
        #expect(BLEUUID(uuid.description) == uuid)
    }

    @Test(
        "malformed UUIDs are rejected",
        arguments: ["", "2A1", "2A190", "XYZW", "6E400001B5A3-F393-E0A9-E50E24DCCA9E", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E0", "0x"])
    func malformed(text: String) {
        #expect(BLEUUID(text) == nil)
    }

    @Test("big-endian byte forms match CoreBluetooth's CBUUID.data")
    func bytes() {
        #expect(BLEUUID(bigEndianBytes: [0x2A, 0x19]) == BLEUUID(0x2A19))
        #expect(BLEUUID(bigEndianBytes: [0x12, 0x34, 0xAB, 0xCD]) == BLEUUID("1234ABCD"))
        #expect(BLEUUID(bigEndianBytes: [0x01, 0x02, 0x03]) == nil)
    }
}

@Suite("Hex")
struct HexTests {
    @Test("encodes lowercase without separators")
    func encode() {
        #expect(Hex.encode([0x00, 0x01, 0xAB, 0xFF]) == "0001abff")
        #expect(Hex.encode(Data()) == "")
    }

    @Test(
        "decodes the spellings agents use",
        arguments: ["01abff", "01ABFF", "01 ab ff", "01:ab:ff", "0x01 0xab 0xff", "0x01abff", "01-AB-FF", "0x01,0xAB,0xFF"])
    func decode(text: String) {
        #expect(Hex.decode(text) == Data([0x01, 0xAB, 0xFF]))
    }

    @Test(
        "rejects odd digit counts, per token, and foreign characters",
        arguments: ["1", "01a", "0g", "01 zz", "0x1 0x2", "1:2:3:4", "012 3", "a b"])
    func rejects(text: String) {
        #expect(Hex.decode(text) == nil)
    }

    @Test("round-trips arbitrary bytes")
    func roundTrip() {
        let bytes = Data((0...255).map(UInt8.init))
        #expect(Hex.decode(Hex.encode(bytes)) == bytes)
    }
}

@Suite("RingBuffer")
struct RingBufferTests {
    @Test("keeps the newest elements and reports evictions")
    func overwritesOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        #expect(buffer.append(1) == nil)
        #expect(buffer.append(2) == nil)
        #expect(buffer.append(3) == nil)
        #expect(buffer.append(4) == 1)
        #expect(buffer.count == 3)
        #expect(buffer.popFirst() == 2)
        #expect(buffer.popFirst() == 3)
        #expect(buffer.first == 4)
        #expect(buffer.popFirst() == 4)
        #expect(buffer.popFirst() == nil)
        #expect(buffer.isEmpty)
    }

    @Test("wraps around repeatedly")
    func wraps() {
        var buffer = RingBuffer<Int>(capacity: 2)
        for value in 0..<10 {
            buffer.append(value)
            #expect(buffer.first == max(0, value - 1))
        }
    }
}

@Suite("GATTResolver")
struct GATTResolverTests {
    let peripheral = PeripheralID(UUID())
    let shared = BLEUUID(0xFFE1)
    var services: [GATTService] {
        [
            GATTService(uuid: BLEUUID(0x180F), characteristics: [GATTCharacteristic(uuid: BLEUUID(0x2A19), properties: .read)]),
            GATTService(uuid: BLEUUID(0xFFE0), characteristics: [GATTCharacteristic(uuid: shared, properties: .notify)]),
            GATTService(uuid: BLEUUID(0xFFF0), characteristics: [GATTCharacteristic(uuid: shared, properties: .write)]),
        ]
    }

    @Test("finds a unique characteristic without a service")
    func unique() throws {
        let resolved = try GATTResolver.resolve(
            CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(0x2A19)), in: services)
        #expect(resolved.address.service == BLEUUID(0x180F))
    }

    @Test("asks for a service when a characteristic UUID is shared")
    func ambiguous() {
        #expect(throws: BLEError.ambiguousCharacteristic(shared, services: [BLEUUID(0xFFE0), BLEUUID(0xFFF0)])) {
            try GATTResolver.resolve(CharacteristicSelector(peripheral: peripheral, characteristic: shared), in: services)
        }
    }

    @Test("an explicit service disambiguates")
    func disambiguated() throws {
        let resolved = try GATTResolver.resolve(
            CharacteristicSelector(peripheral: peripheral, service: BLEUUID(0xFFF0), characteristic: shared), in: services)
        #expect(resolved.characteristic.properties == .write)
    }

    @Test("not-found errors list what exists")
    func notFound() {
        #expect(throws: BLEError.serviceNotFound(BLEUUID(0x1800), available: [BLEUUID(0x180F), BLEUUID(0xFFE0), BLEUUID(0xFFF0)])) {
            try GATTResolver.resolve(
                CharacteristicSelector(peripheral: peripheral, service: BLEUUID(0x1800), characteristic: shared), in: services)
        }
        #expect(throws: BLEError.characteristicNotFound(BLEUUID(0x2A00), service: nil, available: [BLEUUID(0x2A19), shared])) {
            try GATTResolver.resolve(CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(0x2A00)), in: services)
        }
    }
}

@Suite("ScanFilter")
struct ScanFilterTests {
    let id = PeripheralID(UUID())

    /// The name arrives in a scan response, after the advertisement with the services.
    func merged() -> DiscoveredPeripheral {
        var peripheral = DiscoveredPeripheral(
            Advertisement(peripheral: id, rssi: -70, serviceUUIDs: [BLEUUID(0x180D)], manufacturerData: Data([0x4C, 0x00, 0x10])))
        peripheral.merge(Advertisement(peripheral: id, name: "Polar H10", rssi: -60))
        return peripheral
    }

    @Test("matches against data merged across packets")
    func mergedData() {
        let peripheral = merged()
        #expect(peripheral.name == "Polar H10")
        #expect(peripheral.rssi == -60)
        #expect(peripheral.strongestRSSI == -60)
        #expect(peripheral.manufacturerID == 0x004C)
        #expect(
            ScanFilter(nameContains: "polar", serviceUUIDs: [BLEUUID(0x180D)], minimumRSSI: -65, manufacturerID: 0x004C).matches(peripheral)
        )
    }

    @Test(
        "each criterion can exclude",
        arguments: [
            ScanFilter(nameContains: "garmin"),
            ScanFilter(serviceUUIDs: [BLEUUID(0x180F)]),
            ScanFilter(minimumRSSI: -50),
            ScanFilter(manufacturerID: 0x0006),
            ScanFilter(connectableOnly: true),
        ])
    func excludes(filter: ScanFilter) {
        #expect(!filter.matches(merged()))
    }
}
