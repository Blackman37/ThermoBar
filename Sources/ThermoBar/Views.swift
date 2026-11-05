import Charts
import SwiftUI

@MainActor
struct PowerCard: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(monitor.power?.direction ?? "Výkon baterie", systemImage: "battery.100percent")
                    Text(watts(monitor.power?.battery, signed: true)).font(
                        .system(size: 30, weight: .medium, design: .rounded)
                    ).monospacedDigit().foregroundStyle(.mint)
                    Text("+ do baterie · − z baterie").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Příkon adaptéru / USB‑C", systemImage: "powerplug")
                    Text(watts(monitor.power?.adapter)).font(
                        .system(size: 30, weight: .medium, design: .rounded)
                    ).monospacedDigit().foregroundStyle(cyan)
                    Text("Celkem do Macu, včetně nabíjení").font(.system(size: 10)).foregroundStyle(
                        .secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(
                "Orientační údaje systému; mohou se obnovovat pomaleji než zobrazení. Příkon adaptéru není jeho jmenovitý výkon ani odběr ze zásuvky."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(
                "\(monitor.power?.source ?? "Čekám na zdroj") · \(monitor.power?.age ?? "Čekám na údaje napájení")"
            ).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }.font(.system(size: 12, weight: .medium)).padding(18).background(
            panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
struct MetricCard: View {
    let title: String
    let icon: String
    let value: Double?
    let subtitle: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(degrees(value)).font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : color)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(
            panel, in: RoundedRectangle(cornerRadius: 18))
    }
}
@MainActor
struct LoadRow: View {
    let title: String
    let value: Double?
    let color: Color
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 12)).frame(width: 32, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(color).frame(width: g.size.width * min(1, max(0, (value ?? 0) / 100)))
                }
            }.frame(height: 5)
            Text(percent(value)).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(
                width: 50, alignment: .trailing)
        }
    }
}
@MainActor
struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    let toggleHUD: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: "thermometer.medium").font(.system(size: 24)).foregroundStyle(orange)
                        .padding(12).background(orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ThermoBar").font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text(monitor.hardwareLabel).font(
                            .system(size: 10, weight: .medium, design: .monospaced)
                        ).tracking(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(monitor.connected ? Color.mint : .orange).frame(width: 6, height: 6)
                        Text(monitor.connected ? "ŽIVĚ · \(monitor.interval) s" : "ČEKÁM NA ČIDLA").font(
                            .system(size: 10, weight: .semibold, design: .monospaced))
                    }.foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Circle().fill(monitor.thermalColor).frame(width: 8, height: 8)
                    Text(monitor.thermalText).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("TEPELNÝ STAV macOS").font(.system(size: 9, design: .monospaced)).foregroundStyle(
                        .secondary)
                }.padding(14).background(
                    monitor.thermalColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    MetricCard(
                        title: "CPU", icon: "cpu", value: monitor.cpu,
                        subtitle: "Nejteplejší čidlo oblasti CPU", color: orange)
                    MetricCard(
                        title: "GPU", icon: "square.stack.3d.up", value: monitor.gpu,
                        subtitle: "Nejteplejší čidlo oblasti GPU", color: cyan)
                    MetricCard(
                        title: "Baterie", icon: "battery.75percent", value: monitor.battery,
                        subtitle: "Maximum čidel baterie", color: Color(red: 0.77, green: 0.69, blue: 0.99))
                }
                PowerCard(monitor: monitor)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Průběh teplot").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Picker("Historie", selection: $monitor.minutes) {
                            Text("5 min").tag(5)
                            Text("30 min").tag(30)
                            Text("2 h").tag(120)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                    Chart {
                        ForEach(
                            monitor.samples.filter {
                                $0.date >= Date().addingTimeInterval(Double(-monitor.minutes * 60))
                            }
                        ) { s in
                            if let cpu = s.cpu {
                                LineMark(
                                    x: .value("Čas", s.date), y: .value("°C", cpu),
                                    series: .value("Čidlo", "CPU")
                                ).foregroundStyle(orange).interpolationMethod(.linear)
                            }
                            if let gpu = s.gpu {
                                LineMark(
                                    x: .value("Čas", s.date), y: .value("°C", gpu),
                                    series: .value("Čidlo", "GPU")
                                ).foregroundStyle(cyan).interpolationMethod(.linear)
                            }
                        }
                        RuleMark(y: .value("Upozornění", monitor.threshold)).foregroundStyle(
                            .white.opacity(0.22)
                        ).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartYScale(domain: chartTemperatureRange(monitor.samples))
                    .chartXScale(domain: Date().addingTimeInterval(Double(-monitor.minutes * 60))...Date())
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(.white.opacity(0.04))
                            AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(.white.opacity(0.06))
                            AxisValueLabel().foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 155)
                    HStack(spacing: 18) {
                        Label("CPU", systemImage: "circle.fill").foregroundStyle(orange)
                        Label("GPU", systemImage: "circle.fill").foregroundStyle(cyan)
                        Spacer()
                        Text("CPU maximum historie  \(degrees(monitor.peak))C").foregroundStyle(.secondary)
                    }.font(.system(size: 10, weight: .medium))
                }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Aktuální zátěž").font(.system(size: 13, weight: .semibold))
                        LoadRow(title: "CPU", value: monitor.samples.last?.cpuLoad, color: orange)
                        LoadRow(title: "GPU", value: monitor.samples.last?.gpuLoad, color: cyan)
                        LoadRow(
                            title: "RAM",
                            value: monitor.samples.last.flatMap {
                                valid($0.memory / monitor.totalMemory * 100)
                            }, color: .purple)
                        Text(monitor.memorySummary).font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Další údaje").font(.system(size: 13, weight: .semibold))
                        HStack {
                            Text("SSD / NAND")
                            Spacer()
                            Text(
                                monitor.ssd == nil && monitor.economy
                                    ? "V detailech" : "\(degrees(monitor.ssd))C"
                            ).monospacedDigit()
                        }
                        Text("Typ chlazení se nezjišťuje.").foregroundStyle(.secondary)
                    }.font(.system(size: 11)).frame(width: 195)
                }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Image(systemName: monitor.hot ? "exclamationmark.triangle.fill" : "bell").foregroundStyle(
                        monitor.hot ? .orange : .secondary)
                    Text(monitor.hot ? "Teplota překročila tvůj práh" : "Zvýraznit teplotu od").font(
                        .system(size: 12))
                    Stepper(value: $monitor.threshold, in: 60...110, step: 5) {
                        Text("\(Int(monitor.threshold)) °C").font(
                            .system(size: 12, weight: .semibold, design: .monospaced))
                    }.frame(width: 110)
                    Spacer()
                    Button(action: toggleHUD) {
                        Label(
                            monitor.pinned ? "Skrýt miniokno" : "Miniokno nad aplikacemi", systemImage: "pin")
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Úsporné načítání · každých 5 s", isOn: $monitor.economy)
                    Text(
                        "CPU, GPU a baterie se měří průběžně. Ostatní čidla jen v otevřených detailech; zátěž a RAM jen v přehledu."
                    ).font(.system(size: 10)).foregroundStyle(.secondary)
                    Toggle("Průhledné miniokno · jen malé číslo", isOn: $monitor.minimalist)
                    Picker("Údaj v průhledném miniokně", selection: $monitor.hudMetric) {
                        ForEach(HUDMetric.allCases, id: \.self) { metric in Text(metric.label).tag(metric) }
                    }.pickerStyle(.segmented)
                }.font(.system(size: 12)).padding(14).background(
                    panel, in: RoundedRectangle(cornerRadius: 12))
                DisclosureGroup(isExpanded: $monitor.details) {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(monitor.readings) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.key).font(.system(size: 11, design: .monospaced))
                                    Text(r.group.rawValue).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f °C", r.value)).font(
                                    .system(size: 11, design: .monospaced))
                            }.padding(9).background(panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(.top, 10)
                } label: {
                    Text("Všechna čidla · rozbalením načíst detaily (\(monitor.readings.count))").font(
                        .system(size: 12))
                }
                if !monitor.connected {
                    Text(
                        "AppleSMC není dostupné. Teploty nelze přečíst; aplikaci spusť přímo v macOS mimo vývojový sandbox."
                    ).font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text(
                    "CPU/GPU jsou maxima dostupných čidel dané oblasti; přesné umístění Apple veřejně nepopisuje. Přerušovaná čára je tvůj práh upozornění, nikoli limit výrobce. Historie zůstává v paměti nejvýše 2 hodiny."
                ).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                HStack {
                    Button("Export CSV…") { CSVExportDialog.save(monitor.samples) }
                    Button("Nová relace") { monitor.reset() }
                    Spacer()
                    Text("LOKÁLNĚ · BEZ ÚČTU").font(.system(size: 9, design: .monospaced)).tracking(1)
                        .foregroundStyle(.tertiary)
                }.controlSize(.small)
            }.padding(26)
        }.frame(minWidth: 700, idealWidth: 750, minHeight: 700).background(canvas).preferredColorScheme(.dark)
    }
}
@MainActor
struct HUD: View {
    @ObservedObject var monitor: Monitor
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(monitor.thermalColor).frame(width: 6, height: 6)
                Text("THERMOBAR").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(
                    .secondary)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(degrees(monitor.cpu)).foregroundStyle(orange).font(
                        .system(size: 32, weight: .medium, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("GPU").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(degrees(monitor.gpu)).foregroundStyle(cyan).font(
                        .system(size: 32, weight: .medium, design: .rounded))
                }
                Spacer(minLength: 0)
            }.monospacedDigit()
            Text("Baterie  \(degrees(monitor.battery))C").font(
                .system(size: 12, weight: .medium, design: .monospaced)
            ).foregroundStyle(.mint)
            Text("\(monitor.power?.direction ?? "Baterie")  \(watts(monitor.power?.battery, signed: true))")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.mint)
            Text("Adaptér / USB‑C  \(watts(monitor.power?.adapter))").font(
                .system(size: 11, weight: .medium, design: .monospaced)
            ).foregroundStyle(cyan)
            if monitor.hot {
                Text("Překročen práh \(Int(monitor.threshold)) °C").font(.system(size: 10)).foregroundStyle(
                    .orange)
            }
        }.padding(16).frame(width: 242).background(canvas.opacity(0.96)).preferredColorScheme(.dark)
    }
}

@MainActor
struct MinimalHUD: View {
    @ObservedObject var monitor: Monitor
    private var presentation: HUDPresentation { HUDPresentation(monitor: monitor) }
    var body: some View {
        Group {
            if presentation.isCombined {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("IN").font(.system(size: 10, weight: .bold))
                        Spacer()
                        Text(watts(monitor.power?.adapter))
                    }
                    HStack(spacing: 5) {
                        Text("BAT").font(.system(size: 10, weight: .bold))
                        Spacer()
                        Text(watts(monitor.power?.battery, signed: true))
                    }
                }.font(.system(size: 18, weight: .semibold, design: .rounded)).padding(.horizontal, 6)
            } else {
                Text(presentation.text).font(.system(size: 22, weight: .semibold, design: .rounded))
            }
        }.monospacedDigit()
            .foregroundStyle(
                !presentation.isPower && monitor.hudMetric != .batteryTemperature && monitor.hot
                    ? Color.orange : Color.white
            )
            .shadow(color: .black, radius: 2).shadow(color: .black, radius: 1)
            .frame(width: presentation.width, height: presentation.height)
            .contentShape(Rectangle())
            .help(
                "\(monitor.hudMetric.rawValue) · IN = příkon adaptéru, BAT = + nabíjení / − vybíjení · přesun tažením"
            )
    }
}
