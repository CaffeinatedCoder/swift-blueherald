/// Names for frequently met Bluetooth SIG assigned numbers and well-known vendor UUIDs.
///
/// Deliberately a curated subset, not the full registry: these are hints that help an agent
/// read a raw attribute table, and an unknown UUID simply has no name.
public enum AssignedNumbers {
    public static func name(for uuid: BLEUUID) -> String? {
        if let short = uuid.shortValue, short <= 0xFFFF {
            return shortNames[UInt16(short)]
        }
        return vendorNames[uuid]
    }

    public static func companyName(for identifier: UInt16) -> String? {
        companies[identifier]
    }

    private static let shortNames: [UInt16: String] = [
        // Services
        0x1800: "Generic Access",
        0x1801: "Generic Attribute",
        0x1802: "Immediate Alert",
        0x1803: "Link Loss",
        0x1804: "Tx Power",
        0x1805: "Current Time",
        0x1806: "Reference Time Update",
        0x1807: "Next DST Change",
        0x1808: "Glucose",
        0x1809: "Health Thermometer",
        0x180A: "Device Information",
        0x180D: "Heart Rate",
        0x180E: "Phone Alert Status",
        0x180F: "Battery",
        0x1810: "Blood Pressure",
        0x1811: "Alert Notification",
        0x1812: "Human Interface Device",
        0x1813: "Scan Parameters",
        0x1814: "Running Speed and Cadence",
        0x1815: "Automation IO",
        0x1816: "Cycling Speed and Cadence",
        0x1818: "Cycling Power",
        0x1819: "Location and Navigation",
        0x181A: "Environmental Sensing",
        0x181B: "Body Composition",
        0x181C: "User Data",
        0x181D: "Weight Scale",
        0x181E: "Bond Management",
        0x181F: "Continuous Glucose Monitoring",
        0x1820: "Internet Protocol Support",
        0x1821: "Indoor Positioning",
        0x1822: "Pulse Oximeter",
        0x1823: "HTTP Proxy",
        0x1824: "Transport Discovery",
        0x1825: "Object Transfer",
        0x1826: "Fitness Machine",
        0x1827: "Mesh Provisioning",
        0x1828: "Mesh Proxy",
        0xFD6F: "Exposure Notification",
        0xFE59: "Nordic Secure DFU",
        0xFEAA: "Eddystone",

        // Characteristics
        0x2A00: "Device Name",
        0x2A01: "Appearance",
        0x2A02: "Peripheral Privacy Flag",
        0x2A03: "Reconnection Address",
        0x2A04: "Peripheral Preferred Connection Parameters",
        0x2A05: "Service Changed",
        0x2A06: "Alert Level",
        0x2A07: "Tx Power Level",
        0x2A0F: "Local Time Information",
        0x2A19: "Battery Level",
        0x2A1C: "Temperature Measurement",
        0x2A1D: "Temperature Type",
        0x2A1E: "Intermediate Temperature",
        0x2A23: "System ID",
        0x2A24: "Model Number String",
        0x2A25: "Serial Number String",
        0x2A26: "Firmware Revision String",
        0x2A27: "Hardware Revision String",
        0x2A28: "Software Revision String",
        0x2A29: "Manufacturer Name String",
        0x2A2A: "IEEE 11073-20601 Regulatory Certification Data List",
        0x2A2B: "Current Time",
        0x2A35: "Blood Pressure Measurement",
        0x2A37: "Heart Rate Measurement",
        0x2A38: "Body Sensor Location",
        0x2A39: "Heart Rate Control Point",
        0x2A4A: "HID Information",
        0x2A4B: "Report Map",
        0x2A4C: "HID Control Point",
        0x2A4D: "Report",
        0x2A50: "PnP ID",
        0x2A53: "RSC Measurement",
        0x2A5B: "CSC Measurement",
        0x2A5C: "CSC Feature",
        0x2A63: "Cycling Power Measurement",
        0x2A6D: "Pressure",
        0x2A6E: "Temperature",
        0x2A6F: "Humidity",
        0x2A9D: "Weight Measurement",
        0x2A9E: "Weight Scale Feature",
        0x2AA6: "Central Address Resolution",
        0x2B29: "Client Supported Features",
        0x2B2A: "Database Hash",

        // Descriptors
        0x2900: "Characteristic Extended Properties",
        0x2901: "Characteristic User Description",
        0x2902: "Client Characteristic Configuration",
        0x2903: "Server Characteristic Configuration",
        0x2904: "Characteristic Presentation Format",
        0x2905: "Characteristic Aggregate Format",
        0x2906: "Valid Range",
        0x2907: "External Report Reference",
        0x2908: "Report Reference",
    ]

    private static let vendorNames: [BLEUUID: String] = [
        BLEUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")!: "Nordic UART Service",
        BLEUUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")!: "Nordic UART RX",
        BLEUUID("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")!: "Nordic UART TX",
        BLEUUID("7905F431-B5CE-4E99-A40F-4B1E122D00D0")!: "Apple Notification Center Service",
    ]

    private static let companies: [UInt16: String] = [
        0x0000: "Ericsson",
        0x0001: "Nokia",
        0x0002: "Intel",
        0x0006: "Microsoft",
        0x000D: "Texas Instruments",
        0x000F: "Broadcom",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung Electronics",
        0x0087: "Garmin",
        0x00E0: "Google",
        0x02E5: "Espressif",
    ]
}
