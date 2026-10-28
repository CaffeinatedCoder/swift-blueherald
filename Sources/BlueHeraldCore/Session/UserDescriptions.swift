import Foundation

/// Reads the device's own names for its characteristics from their 0x2901 descriptors.
enum UserDescriptions {
    /// Returns `services` with the 0x2901 names filled in. Each read gets at most `perRead` and
    /// all of them together ten seconds, so a device that stalls cannot hold discovery hostage.
    /// Best effort: a read that fails or is slow leaves that name out.
    static func read(
        of id: PeripheralID,
        into services: [GATTService],
        from central: any BLECentral,
        perRead: Duration
    ) async -> [GATTService] {
        let budgetEnds = ContinuousClock.now + .seconds(10)
        var described: [GATTService] = []
        described.reserveCapacity(services.count)
        for service in services {
            var characteristics: [GATTCharacteristic] = []
            characteristics.reserveCapacity(service.characteristics.count)
            for characteristic in service.characteristics {
                guard characteristic.hasUserDescription, ContinuousClock.now < budgetEnds else {
                    characteristics.append(characteristic)
                    continue
                }
                let address = DescriptorAddress(
                    characteristic: CharacteristicAddress(peripheral: id, service: service.uuid, characteristic: characteristic.uuid),
                    descriptor: GATTDescriptor.characteristicUserDescription)
                let value = try? await withDeadline(perRead, operation: "Reading the user description of \(characteristic.uuid)") {
                    try await central.read(address)
                }
                characteristics.append(characteristic.with(userDescription: value.flatMap(text)))
            }
            described.append(GATTService(uuid: service.uuid, isPrimary: service.isPrimary, characteristics: characteristics))
        }
        return described
    }

    /// 0x2901 holds UTF-8 text; devices often pad it with NULs. Kept raw otherwise: whoever shows
    /// it cleans it with `DeviceText`.
    static func text(_ value: Data) -> String? {
        String(validating: value.reversed().drop { $0 == 0 }.reversed(), as: UTF8.self).flatMap { $0.isEmpty ? nil : $0 }
    }
}
