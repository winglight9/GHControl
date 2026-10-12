import AppKit
import SwiftUI

final class GHControlAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: GHControlAppDelegate?

    private var statusItem: NSStatusItem?
    private var openMainWindowAction: (() -> Void)?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        setDockIconVisible(UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true)
        installMenuBarStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func setOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func menuBarIconClicked() {
        showMainWindow()
    }

    private func installMenuBarStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = makeMenuBarIcon()
            image?.isTemplate = true
            button.image = image
            button.toolTip = "GH Control · GPU 功耗控制"
            button.target = self
            button.action = #selector(menuBarIconClicked)
        }
        statusItem = item
    }

    /// A monochrome menu-bar rendering of the app icon's chip-and-sliders mark.
    /// Template rendering lets macOS choose the correct light/dark menu-bar tint.
    private func makeMenuBarIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.35)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let chip = CGPath(roundedRect: CGRect(x: 4.5, y: 4.5, width: 9, height: 9), cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(chip)
            context.strokePath()

            for coordinate: CGFloat in [6, 8, 10, 12] {
                context.move(to: CGPoint(x: coordinate, y: 2.5))
                context.addLine(to: CGPoint(x: coordinate, y: 4.5))
                context.move(to: CGPoint(x: coordinate, y: 13.5))
                context.addLine(to: CGPoint(x: coordinate, y: 15.5))
                context.move(to: CGPoint(x: 2.5, y: coordinate))
                context.addLine(to: CGPoint(x: 4.5, y: coordinate))
                context.move(to: CGPoint(x: 13.5, y: coordinate))
                context.addLine(to: CGPoint(x: 15.5, y: coordinate))
            }
            context.strokePath()

            let sliderKnobs: [(CGFloat, CGFloat)] = [(7, 7), (9, 11), (11, 8.5)]
            for (row, knobX) in sliderKnobs {
                context.move(to: CGPoint(x: 6, y: row))
                context.addLine(to: CGPoint(x: 12, y: row))
                context.strokePath()
                context.fillEllipse(in: CGRect(x: knobX - 0.9, y: row - 0.9, width: 1.8, height: 1.8))
            }
            return true
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "GH Control" && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openMainWindowAction?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first(where: { $0.title == "GH Control" })?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct GHControlApp: App {
    @NSApplicationDelegateAdaptor(GHControlAppDelegate.self) private var appDelegate
    @StateObject private var model = GHControlModel()

    var body: some Scene {
        WindowGroup("GH Control", id: "main") {
            MainWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 900)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
