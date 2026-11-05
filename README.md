# ThermoBar

A local macOS menu bar app for temperature and battery power monitoring, with a floating dashboard and a minimal transparent overlay.

## Features

- CPU, GPU and battery temperatures from available AppleSMC sensors.
- Signed battery power: positive while charging, negative while discharging.
- Measured adapter input power, separate from battery charging power.
- Floating panel or transparent readout, draggable with remembered position.
- Optional 5-second polling, an in-memory temperature history and CSV export.

## Requirements and build

Apple Silicon Mac, macOS 14 or later, and Apple's Command Line Tools or Xcode with Swift 6 or later and Clang. Tested on a MacBook Air M3; other models may expose different sensors. Hardware labels are generic; installed memory is read from the system.

```sh
./build.sh
open build/ThermoBar.app
```

The build uses system frameworks only; it does not download dependencies. The app is locally ad-hoc signed for development. The source-only distribution includes no custom app icon.

## Tests and CI

```sh
./test.sh
```

This runs deterministic Swift Testing tests without accessing live sensors. The wrapper locates the toolchain's Swift Testing macro plugin when needed. The package can also be tested with `swift test` in toolchains that discover the plugin automatically. Swift 6 enforces concurrency checking, and builds and tests treat Swift compiler warnings as errors.

GitHub Actions runs tests, the C static analyzer, and an arm64 app build with signature verification. No external Swift packages are used.

For a separate command-line integration check on a compatible Mac:

```sh
build/ThermoBar.app/Contents/MacOS/ThermoBar --self-test
```

This starts a short sampling session without opening the UI. AppleSMC access may be unavailable in development sandboxes. An optional `--csv PATH` writes the test session to that explicit path and may overwrite an existing file there.

## Code organization

- `Sources/SensorBridge`: C access to AppleSMC, IORegistry and system counters.
- `Sources/ThermoBar/SensorSampler.swift`: serialized reads, discovery and recovery in a worker actor.
- `Sources/ThermoBar/Monitor.swift`: main-actor UI state, settings and polling lifecycle.
- `Models.swift` and `CSVExporter.swift`: data models, history, power transitions and export serialization.
- `Views.swift`, `Presentation.swift`, `AppDelegate.swift` and `main.swift`: dashboard, overlays and app/CLI entry points.
- `Tests/ThermoBarTests`: regression tests and in-memory sensor fixtures.

See [architecture and tradeoffs](docs/architecture.md) and [the AI-assisted development workflow](docs/ai-development.md).

## Privacy and limitations

There are no network requests, accounts, telemetry uploads, privileged helpers or runtime shell commands in the app. Settings and overlay position are stored in UserDefaults. Normal session history stays in memory for up to two hours; CSV is saved only to a chosen location.

AppleSMC and parts of IORegistry used here are private or undocumented interfaces. Sensor availability and interpretation can change. Values are approximate; system power data may refresh more slowly than the display. The app displays the system record's update age and waits for new samples during power-source transitions. If a timestamp is unavailable, unchanged electrical values keep the app waiting rather than being treated as fresh data. Temporarily unavailable temperature sensors are retried. The first CPU-load value after a sampling pause is unavailable while its baseline is primed.

The app only monitors: it does not change charging limits, fan settings or battery-controller settings. Temperature thresholds are user display thresholds, not manufacturer limits. Do not use these readings as a replacement for the Mac's own thermal protections.

Adapter input is the reported total DC input to the Mac, including battery charging. It is not the adapter's rated wattage, AC wall-socket consumption or a measurement of each USB-C peripheral. MagSafe input is also part of adapter input.

This repository contains source and project documentation only. Local measurements, binaries, caches and archives are excluded by `.gitignore`. Build a release with your own distribution setup if you intend to ship an app binary to others; the local ad-hoc build is not a notarized release.

## References

- Battery voltage/current interpretation: [BetterBattery](https://github.com/michaelmax98/BetterBattery).
- IORegistry battery fields: [M1 Apple Mac Battery Statistics](https://gist.github.com/nhecker/8e850773ff229724ce361967cc227d27/0f2eb0000da7b548b555e56ea4dcc611b6816aa5).

## License

A public reuse license has not yet been selected. Add your chosen LICENSE before advertising the project as open source.
