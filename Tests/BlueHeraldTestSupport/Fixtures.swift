public import BlueHeraldCore
public import Foundation

/// A small, realistic attribute table: Device Information, Battery, and a Nordic UART service.
public enum Fixtures {
    public static let batteryService = BLEUUID(0x180F)
    public static let batteryLevel = BLEUUID(0x2A19)
    public static let deviceInformation = BLEUUID(0x180A)
    public static let manufacturerName = BLEUUID(0x2A29)
    public static let userDescription = GATTDescriptor.characteristicUserDescription
    public static let uartService = BLEUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")!
    public static let uartRX = BLEUUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")!
    public static let uartTX = BLEUUID("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")!

    public static let services: [GATTService] = [
        GATTService(
            uuid: deviceInformation,
            characteristics: [GATTCharacteristic(uuid: manufacturerName, properties: [.read])]),
        GATTService(
            uuid: batteryService,
            characteristics: [
                GATTCharacteristic(
                    uuid: batteryLevel, properties: [.read, .notify],
                    descriptors: [
                        GATTDescriptor(uuid: GATTDescriptor.clientCharacteristicConfiguration),
                        GATTDescriptor(uuid: userDescription),
                    ])
            ]),
        GATTService(
            uuid: uartService,
            characteristics: [
                GATTCharacteristic(
                    uuid: uartRX, properties: [.write, .writeWithoutResponse],
                    descriptors: [GATTDescriptor(uuid: userDescription)]),
                GATTCharacteristic(
                    uuid: uartTX, properties: [.notify],
                    descriptors: [
                        GATTDescriptor(uuid: GATTDescriptor.clientCharacteristicConfiguration),
                        GATTDescriptor(uuid: userDescription),
                    ]),
            ]),
    ]

    public static func meter(id: PeripheralID = PeripheralID(UUID()), rssi: Int = -55) -> FakeCentral.Device {
        FakeCentral.Device(
            id: id,
            name: "BB-500 Meter",
            rssi: rssi,
            advertisedServices: [uartService],
            manufacturerData: Data([0x59, 0x00, 0x01]),
            services: services,
            values: [
                manufacturerName: Data("Voltcraft\0".utf8),
                batteryLevel: Data([87]),
            ],
            // Real devices pad these; the session trims NULs and whitespace.
            userDescriptions: [batteryLevel: "Battery\0", uartRX: "Data In ", uartTX: "Data Out"])
    }

    public static func beacon(rssi: Int = -80) -> FakeCentral.Device {
        FakeCentral.Device(name: "Beacon", rssi: rssi, manufacturerData: Data([0x4C, 0x00, 0x02, 0x15]))
    }
}
