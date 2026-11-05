import Foundation
import SensorBridge

enum SensorGroup: String, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case battery = "Baterie"
    case storage = "SSD / NAND"
    case other = "Další čidla"
}

enum HUDMetric: String, CaseIterable, Sendable {
    // Raw values preserve settings from earlier releases.
    case cpu = "CPU"
    case gpu = "GPU"
    case batteryTemperature = "Baterie"
    case batteryPower = "Výkon baterie"
    case adapterPower = "Příkon adaptéru"
    case combinedPower = "Adaptér + baterie"

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .batteryTemperature: return "Baterie °C"
        case .batteryPower: return "Baterie W"
        case .adapterPower: return "Adaptér W"
        case .combinedPower: return "Obojí W"
        }
    }
}

struct Reading: Identifiable, Sendable {
    let key: String
    let value: Double
    var id: String { key }
    var group: SensorGroup {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf")
            || ["TCMz", "TCMb"].contains(key)
        {
            return .cpu
        }
        if key.hasPrefix("Tg") { return .gpu }
        if key.hasPrefix("TB") { return .battery }
        if key == "TH0T" || key == "TH0x" { return .storage }
        return .other
    }
}
struct Sample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let battery: Double?
    let batteryWatts: Double?
    let adapterWatts: Double?
    let powerUpdated: Date?
    let cpuLoad: Double?
    let gpuLoad: Double?
    let memory: Double
    let thermal: String
}
func valid(_ value: Double) -> Double? { value.isFinite ? value : nil }
func degrees(_ value: Double?) -> String { value.map { String(format: "%.0f°", $0) } ?? "—" }
func percent(_ value: Double?) -> String { value.map { String(format: "%.0f %%", $0) } ?? "—" }
func watts(_ value: Double?, signed: Bool = false) -> String {
    value.map { String(format: signed && abs($0) >= 0.05 ? "%+.1f W" : "%.1f W", abs($0) < 0.05 ? 0 : $0) }
        ?? "—"
}
struct BatteryPower: Sendable {
    let waiting: Bool
    let battery: Double?
    let adapter: Double?
    let voltage: Double?
    let amperage: Double?
    let updated: Date?
    let external: Int32
    init(_ raw: PowerReading, waiting: Bool = false) {
        self.waiting = waiting
        battery = waiting ? nil : valid(raw.battery_watts)
        adapter = waiting && raw.external_connected == 1 ? nil : valid(raw.adapter_watts)
        voltage = valid(raw.voltage)
        amperage = valid(raw.amperage)
        updated = valid(raw.updated_unix).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        external = raw.external_connected
    }
    var direction: String {
        guard let battery else {
            return waiting ? "Čekám na nový údaj baterie" : "Údaj baterie není dostupný"
        }
        if battery >= 0.05 { return "Nabíjení baterie" }
        if battery <= -0.05 { return "Vybíjení baterie" }
        return "Baterie bez toku energie"
    }
    var source: String {
        external == 1 ? "Adaptér připojen" : (external == 0 ? "Napájení z baterie" : "Zdroj napájení neznámý")
    }
    var age: String {
        guard let updated else { return "Stáří údajů není dostupné" }
        let elapsed = Date().timeIntervalSince(updated)
        guard elapsed.isFinite,
            let seconds = Int(exactly: max(0, elapsed).rounded(.down))
        else {
            return "Stáří údajů není dostupné"
        }
        return "Stáří údajů systému: \(seconds) s"
    }
}
// IORegistry can change ExternalConnected before refreshing current/voltage.
// Hide the previous flow until a new electrical sample arrives.
struct PowerTransitionFilter {
    // Keep the last known source across temporarily unavailable registry records.
    private var previousKnown: PowerReading?
    private var awaiting: PowerReading?

    mutating func ingest(_ raw: PowerReading) -> BatteryPower {
        guard raw.external_connected == 0 || raw.external_connected == 1 else {
            return BatteryPower(raw, waiting: true)
        }
        if let previousKnown,
            raw.external_connected != previousKnown.external_connected
        {
            awaiting = previousKnown
        }
        if let old = awaiting, hasFreshElectricalSample(raw, since: old) {
            awaiting = nil
        }
        previousKnown = raw
        // Zero flow is valid; only a positive flow contradicts battery power.
        let inconsistent = raw.external_connected == 0 && raw.battery_watts > 0
        return BatteryPower(raw, waiting: awaiting != nil || inconsistent)
    }

    private func hasFreshElectricalSample(_ raw: PowerReading, since old: PowerReading) -> Bool {
        func changed(_ current: Double, _ previous: Double) -> Bool {
            // Missing data never proves that a fresh sample arrived.
            current.isFinite && previous.isFinite && current != previous
        }
        let newerTime =
            raw.updated_unix.isFinite && old.updated_unix.isFinite
            && raw.updated_unix > 0 && old.updated_unix > 0
            && raw.updated_unix > old.updated_unix
        let newlyAvailable =
            raw.amperage.isFinite && raw.voltage.isFinite
            && (!old.amperage.isFinite || !old.voltage.isFinite)
        return newerTime || newlyAvailable || changed(raw.amperage, old.amperage)
            || changed(raw.voltage, old.voltage)
    }
}

func safeThreshold(_ value: Double) -> Double {
    value.isFinite && (60...110).contains(value) ? value : 90
}

func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "Normální tepelný stav"
    case .fair: return "Zvýšená tepelná zátěž"
    case .serious: return "Vysoká tepelná zátěž"
    case .critical: return "Kritická tepelná zátěž"
    @unknown default: return "Neznámý stav"
    }
}

struct SampleHistory {
    private(set) var samples: [Sample] = []

    mutating func append(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-7200)
        samples.removeAll { $0.date < cutoff }
    }

    mutating func clear() { samples.removeAll() }
}

func chartTemperatureRange(_ samples: [Sample]) -> ClosedRange<Double> {
    let values = samples.flatMap { [$0.cpu, $0.gpu].compactMap { $0 }.filter(\.isFinite) }
    return min(20, (values.min() ?? 25) - 5)...max(110, (values.max() ?? 0) + 5)
}
