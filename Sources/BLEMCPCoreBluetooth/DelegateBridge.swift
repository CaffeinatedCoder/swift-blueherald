#if canImport(CoreBluetooth)
import BLEMCPCore
@preconcurrency import CoreBluetooth
import Foundation

/// Receives CoreBluetooth delegate callbacks and forwards them into `CoreBluetoothCentral`.
///
/// CoreBluetooth calls these methods on the queue that is the actor's executor, so
/// `assumeIsolated` enters the actor synchronously; it traps if that invariant is ever broken
/// rather than racing silently.
final class DelegateBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: CoreBluetoothCentral?

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.assumeIsolated { $0.handleStateUpdate() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisement = Advertisement(peripheral: peripheral, data: advertisementData, rssi: RSSI)
        owner?.assumeIsolated { $0.handleDiscovery(of: peripheral, advertisement) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        owner?.assumeIsolated { $0.handleConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        owner?.assumeIsolated { $0.handleFailedConnect(peripheral, error: error) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleDisconnect(peripheral, error: error) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        owner?.assumeIsolated { $0.handleServicesDiscovered(on: peripheral, error: error) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleCharacteristicsDiscovered(for: service, error: error) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleDescriptorsDiscovered(for: characteristic, error: error) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleValueUpdate(of: characteristic, on: peripheral, error: error) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleWrite(to: characteristic, error: error) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        owner?.assumeIsolated { $0.handleNotificationStateUpdate(of: characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        owner?.assumeIsolated { $0.handleDescriptorValueUpdate(of: descriptor, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {
        owner?.assumeIsolated { $0.handleDescriptorWrite(to: descriptor, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        let rssi = RSSI.intValue
        owner?.assumeIsolated { $0.handleRSSI(rssi, of: peripheral, error: error) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        owner?.assumeIsolated { $0.handleReadyToWriteWithoutResponse(peripheral) }
    }
}
#endif
