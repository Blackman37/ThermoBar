import AppKit
import Foundation

// Pure serialization: no UI, filesystem writes or sensor access.
enum CSVExporter {
    static let header =
        "timestamp,cpu_area_max_c,gpu_area_max_c,battery_max_c,cpu_load_percent,gpu_load_percent,memory_used_gib,macos_thermal_state,battery_power_w,adapter_input_w,power_source_updated_at"

    static func render(_ samples: [Sample]) -> String {
        let formatter = ISO8601DateFormatter()
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func field(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        let rows = samples.map { sample in
            [
                formatter.string(from: sample.date),
                number(sample.cpu), number(sample.gpu), number(sample.battery),
                number(sample.cpuLoad), number(sample.gpuLoad), number(sample.memory),
                field(sample.thermal), number(sample.batteryWatts), number(sample.adapterWatts),
                sample.powerUpdated.map { formatter.string(from: $0) } ?? "",
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

@MainActor
enum CSVExportDialog {
    static func save(_ samples: [Sample]) {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = "ThermoBar-\(Date().formatted(.iso8601.year().month().day())).csv"
        dialog.allowedContentTypes = [.commaSeparatedText]
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do { try CSVExporter.render(samples).write(to: url, atomically: true, encoding: .utf8) } catch {
            NSAlert(error: error).runModal()
        }
    }
}
