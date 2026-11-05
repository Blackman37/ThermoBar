import SwiftUI

let orange = Color(red: 1, green: 0.64, blue: 0.35)
let cyan = Color(red: 0.28, green: 0.83, blue: 0.88)
let canvas = Color(red: 0.055, green: 0.065, blue: 0.09)
let panel = Color(red: 0.09, green: 0.105, blue: 0.14)

@MainActor
extension Monitor {
    var hardwareLabel: String {
        guard totalMemory.isFinite, totalMemory > 0 else { return "APPLE SILICON" }
        return String(format: "APPLE SILICON  /  %.0f GiB RAM", totalMemory)
    }

    var memorySummary: String {
        guard let used = samples.last?.memory, used.isFinite, totalMemory.isFinite, totalMemory > 0 else {
            return "Údaj paměti není dostupný"
        }
        return String(format: "Paměť %.1f / %.0f GiB · aktivní + wired + komprimovaná", used, totalMemory)
    }

    var thermalColor: Color { thermal == .nominal ? .mint : (thermal == .fair ? .yellow : .red) }
}

@MainActor
struct HUDPresentation {
    let metric: HUDMetric
    let temperature: Double?
    let power: BatteryPower?

    init(monitor: Monitor) {
        metric = monitor.hudMetric
        power = monitor.power
        switch metric {
        case .batteryTemperature: temperature = monitor.battery
        case .gpu: temperature = monitor.gpu
        default: temperature = monitor.cpu
        }
    }

    var isCombined: Bool { metric == .combinedPower }
    var isPower: Bool { [.batteryPower, .adapterPower, .combinedPower].contains(metric) }
    var width: CGFloat { isCombined ? 146 : (isPower ? 126 : 72) }
    var height: CGFloat { isCombined ? 62 : 38 }
    var text: String {
        switch metric {
        case .batteryPower: return watts(power?.battery, signed: true)
        case .adapterPower: return watts(power?.adapter)
        default: return degrees(temperature)
        }
    }
}
