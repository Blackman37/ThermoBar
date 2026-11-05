import Foundation
import SensorBridge
import Testing

struct PowerDecodingTests {
    private func properties(current: NSNumber, external: Bool = false, voltage: Int = 12000) -> CFDictionary {
        [
            "Voltage": voltage,
            "InstantAmperage": current,
            "ExternalConnected": external,
            "UpdateTime": 100,
            "PowerTelemetryData": ["SystemPowerIn": 30000],
        ] as CFDictionary
    }

    @Test(arguments: [Int64(-1000), Int64(4_294_966_296)])
    func signedAndWrappedCurrent(current: Int64) {
        let reading = power_from_properties(properties(current: NSNumber(value: current)))
        #expect(reading.amperage == -1)
        #expect(reading.voltage == 12)
        #expect(reading.battery_watts == -12)
        #expect(reading.adapter_watts == 0)
    }

    @Test func wrapped64BitCurrent() {
        let reading = power_from_properties(properties(current: NSNumber(value: UInt64.max - 999)))
        #expect(reading.amperage == -1)
        #expect(reading.battery_watts == -12)
    }

    @Test func chargingAndAdapterInputAreSeparate() {
        let reading = power_from_properties(properties(current: 1000, external: true))
        #expect(reading.battery_watts == 12)
        #expect(reading.adapter_watts == 30)
        #expect(reading.external_connected == 1)
        #expect(reading.updated_unix == 100)
    }

    @Test func missingAndOutOfRangePropertiesStayUnavailable() {
        let empty = power_from_properties([:] as CFDictionary)
        #expect(empty.battery_watts.isNaN)
        #expect(empty.adapter_watts.isNaN)
        #expect(empty.updated_unix.isNaN)
        #expect(empty.external_connected == -1)
        #expect(power_from_properties(nil).battery_watts.isNaN)
        #expect(power_from_properties(properties(current: 1000, voltage: 0)).battery_watts.isNaN)
        #expect(power_from_properties(properties(current: 999999)).battery_watts.isNaN)
        let fallback = power_from_properties(["Voltage": 12000, "Amperage": -500] as CFDictionary)
        #expect(fallback.battery_watts == -6)
        let malformed = power_from_properties(
            ["Voltage": "bad", "InstantAmperage": "bad", "ExternalConnected": "bad"] as CFDictionary)
        #expect(malformed.battery_watts.isNaN)
        #expect(malformed.external_connected == -1)
    }
}
