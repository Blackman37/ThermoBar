import AppKit
import SwiftUI

// SwiftUI consumes mouse events over labels, so background dragging alone is
// insufficient for a borderless panel. Handle the drag across the whole panel.
@MainActor
final class DraggablePanel: NSPanel {
    var hasCloseButton = true
    private var dragStart: NSPoint?
    private var originalOrigin: NSPoint?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView {
            let point = event.locationInWindow
            let closeArea = NSRect(
                x: contentView.bounds.width - 44,
                y: contentView.bounds.height - 44,
                width: 44, height: 44)
            if !hasCloseButton || !closeArea.contains(point) {
                dragStart = convertPoint(toScreen: point)
                originalOrigin = frame.origin
                return
            }
        }
        if event.type == .leftMouseDragged, let start = dragStart, let origin = originalOrigin {
            let current = convertPoint(toScreen: event.locationInWindow)
            setFrameOrigin(NSPoint(x: origin.x + current.x - start.x, y: origin.y + current.y - start.y))
            return
        }
        if event.type == .leftMouseUp, dragStart != nil {
            dragStart = nil
            originalOrigin = nil
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    var status: NSStatusItem!
    var window: NSWindow!
    var hud: NSPanel?
    var minimalMenu: NSMenuItem!
    var economyMenu: NSMenuItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "cz.local.ThermoBar")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let menu = NSMenu()
        menu.addItem(withTitle: "Otevřít přehled", action: #selector(showWindow), keyEquivalent: "").target =
            self
        menu.addItem(withTitle: "Zobrazit / skrýt miniokno", action: #selector(toggleHUD), keyEquivalent: "")
            .target = self
        minimalMenu = menu.addItem(
            withTitle: "Průhledné miniokno · jen číslo", action: #selector(toggleMinimal), keyEquivalent: "")
        minimalMenu.target = self
        economyMenu = menu.addItem(
            withTitle: "Úsporné načítání (5 s)", action: #selector(toggleEconomy), keyEquivalent: "")
        economyMenu.target = self
        let metricMenu = NSMenu()
        for metric in HUDMetric.allCases {
            let name = metric.rawValue
            let item = metricMenu.addItem(
                withTitle: name, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.target = self
        }
        let metricItem = menu.addItem(withTitle: "Údaj v průhledném miniokně", action: nil, keyEquivalent: "")
        metricItem.submenu = metricMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ukončit ThermoBar", action: #selector(quit), keyEquivalent: "q").target =
            self
        status.menu = menu
        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.status.button?.title = "\(self.monitor.hot ? "⚠ " : "")CPU \(degrees(self.monitor.cpu))"
            self.minimalMenu.state = self.monitor.minimalist ? .on : .off
            self.economyMenu.state = self.monitor.economy ? .on : .off
            for item in metricMenu.items {
                item.state = item.title == self.monitor.hudMetric.rawValue ? .on : .off
            }
            self.status.button?.toolTip =
                "CPU \(degrees(self.monitor.cpu))C · GPU \(degrees(self.monitor.gpu))C · Baterie \(degrees(self.monitor.battery))C\n\(self.monitor.power?.direction ?? "Baterie"): \(watts(self.monitor.power?.battery, signed: true)) · Adaptér: \(watts(self.monitor.power?.adapter))\n\(self.monitor.thermalText)"
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        monitor.onHUDChange = { [weak self] in self?.rebuildHUD() }
        window.delegate = self
        window.title = "ThermoBar · Teploty Macu"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 710, height: 600)
        window.contentView = NSHostingView(
            rootView: Dashboard(monitor: monitor, toggleHUD: { [weak self] in self?.toggleHUD() }))
        window.center()
        showWindow()
    }
    @objc func showWindow() {
        monitor.dashboardVisible = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { monitor.dashboardVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { monitor.dashboardVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.dashboardVisible = true }
    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? DraggablePanel, panel.isVisible else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: "hudX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "hudTop")
    }
    @objc func toggleMinimal() { monitor.minimalist.toggle() }
    @objc func toggleEconomy() { monitor.economy.toggle() }
    @objc func selectMetric(_ sender: NSMenuItem) {
        if let metric = HUDMetric(rawValue: sender.title) { monitor.hudMetric = metric }
    }
    func rebuildHUD() {
        guard let hud else { return }
        let visible = hud.isVisible
        let origin = NSPoint(x: hud.frame.minX, y: hud.frame.maxY)
        hud.orderOut(nil)
        self.hud = nil
        if visible {
            toggleHUD()
            self.hud?.setFrameTopLeftPoint(origin)
        }
    }
    @objc func toggleHUD() {
        if let hud, hud.isVisible {
            hud.orderOut(nil)
            monitor.pinned = false
            return
        }
        if hud == nil {
            let p = DraggablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 274, height: 150),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.hasCloseButton = !monitor.minimalist
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = !monitor.minimalist
            if monitor.minimalist {
                p.contentView = NSHostingView(rootView: MinimalHUD(monitor: monitor))
                p.setContentSize(
                    NSSize(
                        width: HUDPresentation(monitor: monitor).width,
                        height: HUDPresentation(monitor: monitor).height))
            } else {
                let view = NSHostingView(
                    rootView: HUD(monitor: monitor, close: { [weak self] in self?.toggleHUD() }))
                view.wantsLayer = true
                view.layer?.cornerRadius = 16
                view.layer?.masksToBounds = true
                p.contentView = view
                p.setContentSize(NSSize(width: 274, height: 210))
            }
            if let screen = NSScreen.main {
                p.setFrameTopLeftPoint(
                    NSPoint(x: screen.visibleFrame.maxX - 295, y: screen.visibleFrame.maxY - 20))
            }
            if let x = UserDefaults.standard.object(forKey: "hudX") as? Double,
                let top = UserDefaults.standard.object(forKey: "hudTop") as? Double,
                x.isFinite, top.isFinite
            {
                let candidate = NSRect(
                    x: x, y: top - p.frame.height, width: p.frame.width, height: p.frame.height)
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(candidate) }) {
                    p.setFrameTopLeftPoint(NSPoint(x: x, y: top))
                }
            }
            p.delegate = self
            hud = p
        }
        hud?.orderFrontRegardless()
        monitor.pinned = true
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}
