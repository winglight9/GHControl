import AppKit
import SwiftUI

final class GHControlAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: GHControlAppDelegate?

    private var statusItem: NSStatusItem?
    private var openMainWindowAction: (() -> Void)?
    private var restorePowerLimitAction: (() -> (success: Bool, detail: String))?
    private var isOpeningMainWindow = false

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

    func setRestorePowerLimitAction(_ action: @escaping () -> (success: Bool, detail: String)) {
        restorePowerLimitAction = action
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("GH Control received a normal termination request.")
        sender.activate(ignoringOtherApps: true)
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "退出 GH Control？"
        confirmation.informativeText = "退出前会重新发送 75 W 默认请求，并确认 AMD 驱动 last-set 缓存读回 75 W。该缓存不是实时硬件上限读回。完全退出后，当前低功耗请求将取消；要继续调节需重新打开 GH Control。"
        confirmation.addButton(withTitle: "恢复默认并退出")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        guard let restorePowerLimitAction else {
            return keepAppOpenAfterRestoreFailure("功耗控制状态尚未读取，无法确认已恢复默认值。")
        }
        let restoration = restorePowerLimitAction()
        guard restoration.success else {
            return keepAppOpenAfterRestoreFailure(restoration.detail)
        }
        return .terminateNow
    }

    func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func menuBarIconClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem?.button {
            let menu = NSMenu()
            let openItem = NSMenuItem(title: "打开 GH Control", action: #selector(openMainWindowFromMenu), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "退出 GH Control…", action: #selector(terminateFromMenu), keyEquivalent: "")
            quitItem.target = self
            menu.addItem(quitItem)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        showMainWindow()
    }

    @objc private func openMainWindowFromMenu() {
        showMainWindow()
    }

    @objc private func terminateFromMenu() {
        NSApp.terminate(nil)
    }

    private func keepAppOpenAfterRestoreFailure(_ detail: String) -> NSApplication.TerminateReply {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未能确认驱动已接受 75 W 请求"
        alert.informativeText = "\(detail)\n\nGH Control 会保持打开，避免常规退出后遗留低功耗请求。请检查驱动连接、重试恢复 75 W，再退出。"
        alert.addButton(withTitle: "返回 GH Control")
        _ = alert.runModal()
        return .terminateCancel
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if let window = NSApp.windows.first(where: { $0.title == "GH Control" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard !isOpeningMainWindow, let openMainWindowAction else { return }
        isOpeningMainWindow = true
        openMainWindowAction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isOpeningMainWindow = false
            if let window = NSApp.windows.first(where: { $0.title == "GH Control" }) {
                window.makeKeyAndOrderFront(nil)
            }
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
            CommandGroup(replacing: .appTermination) {
                Button("退出 GH Control…") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
