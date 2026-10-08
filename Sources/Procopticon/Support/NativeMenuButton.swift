import AppKit
import SwiftUI

/// A button that opens an AppKit menu, built when it's clicked. A SwiftUI `Menu` in a window that
/// updates every refresh (the toolbar, the summary panel) gets its items re-applied on each update,
/// and an open menu then rebuilds its rows under the pointer: hovering lagged and could beachball.
/// SwiftUI never touches this menu.
struct NativeMenuButton<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder var label: Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            label
        }
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// The AppKit view the menu opens below.
final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let below = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
