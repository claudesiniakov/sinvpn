import SwiftUI
import AppKit

@main
struct SinVpnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
                .environment(model.updater)
        } label: {
            Image(nsImage: model.menuBarImage)
                .accessibilityLabel("SinVpn")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flush()
    }
}

/// Значок строки меню: слово VPN в рамке. Шаблонное изображение — цвет подбирает система.
@MainActor
enum MenuBarIcon {
    /// Все VPN выключены: контурная рамка.
    static let off = make(filled: false, alpha: 1)
    /// Фаза мигания во время подключения.
    static let dim = make(filled: false, alpha: 0.35)
    /// VPN подключён: рамка залита, буквы вырезаны.
    static let on = make(filled: true, alpha: 1)

    private static func make(filled: Bool, alpha: CGFloat) -> NSImage {
        let size = NSSize(width: 29, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = NSColor.black.withAlphaComponent(alpha)
            let kern: CGFloat = 0.7
            let text = NSAttributedString(string: "VPN", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .heavy),
                .kern: kern,
                .foregroundColor: color,
            ])
            let textSize = text.size()
            let origin = NSPoint(
                x: (rect.width - (textSize.width - kern)) / 2,
                y: (rect.height - textSize.height) / 2
            )
            if filled {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: origin)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
                frame.lineWidth = 1.5
                color.setStroke()
                frame.stroke()
                text.draw(at: origin)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
