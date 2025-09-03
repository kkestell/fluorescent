import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.state = .active
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
    }
}

private struct GridLayout {
    let rows: Int
    let cols: Int
    let icon: CGFloat
    let cell: CGFloat
    let hSpacing: CGFloat
    let vSpacing: CGFloat
    let pad: CGFloat
    let corner: CGFloat
}

private let kTileInsetRatio: CGFloat = 0.1
private let kSpacingBoost: CGFloat   = 0

private func computeLayout(total: Int, in size: CGSize) -> GridLayout {
    let baseIcon: CGFloat = 96
    let baseHSpacing: CGFloat = 4
    let baseVSpacing: CGFloat = 8
    let basePad: CGFloat = 30

    let W = size.width
    let H = size.height * 0.8

    let n = max(total, 1)
    var bestRows = 1
    var bestIcon: CGFloat = 16
    let cellFactor = (1 + 2 * kTileInsetRatio)

    for rows in 1...n {
        let cols = Int(ceil(Double(n) / Double(rows)))
        let maxCellW = (W - 2 * basePad - CGFloat(cols - 1) * (baseHSpacing * kSpacingBoost)) / CGFloat(cols)
        let maxCellH = (H - 2 * basePad - CGFloat(rows - 1) * (baseVSpacing * kSpacingBoost)) / CGFloat(rows)
        let maxIconW = maxCellW / cellFactor
        let maxIconH = maxCellH / cellFactor
        let candidate = floor(max(16, min(baseIcon, min(maxIconW, maxIconH))))
        if candidate > bestIcon { bestIcon = candidate; bestRows = rows }
    }

    let rows = bestRows
    let cols = Int(ceil(Double(n) / Double(rows)))
    let s = bestIcon / baseIcon

    let icon = bestIcon
    let cell = floor(icon * cellFactor)

    return GridLayout(
        rows: rows,
        cols: cols,
        icon: icon,
        cell: cell,
        hSpacing: max(4, floor(baseHSpacing * s * kSpacingBoost)),
        vSpacing: max(8, floor(baseVSpacing * s * kSpacingBoost)),
        pad: max(12, floor(basePad * s)),
        corner: max(4, floor(8 * s))
    )
}

final class Overlay {
    private let window: NSWindow
    private let host = NSHostingController(rootView: SwitcherView(items: [], index: 0, onTapIndex: { _ in }))
    private var items: [AppItem] = []
    private(set) var index: Int = 0

    var onActivate: ((NSRunningApplication) -> Void)?

    var current: NSRunningApplication? {
        items.indices.contains(index) ? items[index].app : nil
    }

    init() {
        let screen = NSScreen.main?.frame ?? .zero
        window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hasShadow = false

        window.contentView = host.view
        host.view.frame = screen
        host.view.autoresizingMask = [.width, .height]

        hide()
    }

    func enableInteraction(_ enabled: Bool) {
        window.ignoresMouseEvents = !enabled
        if enabled {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hitTest(global p: CGPoint) -> Bool {
        window.isVisible && window.frame.contains(p)
    }

    func reload(_ apps: [NSRunningApplication]) {
        items = apps.map {
            AppItem(app: $0, icon: $0.icon ?? NSImage(named: NSImage.applicationIconName)!)
        }
        index = 0
        host.rootView = SwitcherView(items: items, index: index, onTapIndex: { [weak self] tapped in
            guard let self else { return }
            self.index = tapped
            if tapped < self.items.count {
                self.onActivate?(self.items[tapped].app)
            }
        })
    }

    func moveForward() {
        guard !items.isEmpty else { return }
        index = (index + 1) % items.count
        host.rootView = SwitcherView(items: items, index: index, onTapIndex: host.rootView.onTapIndex)
    }

    func moveBackward() {
        guard !items.isEmpty else { return }
        index = (index - 1 + items.count) % items.count
        host.rootView = SwitcherView(items: items, index: index, onTapIndex: host.rootView.onTapIndex)
    }

    func jump(to n: Int) {
        guard n > 0, n <= items.count else { return }
        index = n - 1
        host.rootView = SwitcherView(items: items, index: index, onTapIndex: host.rootView.onTapIndex)
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }
}

struct AppItem: Identifiable, Equatable {
    let id = UUID()
    let app: NSRunningApplication
    let icon: NSImage
}

struct SwitcherView: View {
    let items: [AppItem]
    let index: Int
    let onTapIndex: (Int) -> Void

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            GeometryReader { geo in
                let layout = computeLayout(total: items.count, in: geo.size)
                let tileCorner = max(4, layout.icon * 0.10)
                let tileInset  = round(layout.icon * kTileInsetRatio)

                VStack(spacing: layout.vSpacing) {
                    ForEach(0..<layout.rows, id: \.self) { r in
                        HStack(spacing: layout.hSpacing) {
                            ForEach(0..<layout.cols, id: \.self) { c in
                                let idx = r * layout.cols + c
                                if idx < items.count {
                                    let it = items[idx]

                                    ZStack {
                                        if idx == index {
                                            RoundedRectangle(cornerRadius: tileCorner, style: .continuous)
                                                .fill(Color.black.opacity(0.45))
                                                .frame(width: layout.icon + 2 * tileInset,
                                                       height: layout.icon + 2 * tileInset)
                                        } else {
                                            Color.clear
                                                .frame(width: layout.icon + 2 * tileInset,
                                                       height: layout.icon + 2 * tileInset)
                                        }

                                        Image(nsImage: it.icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: layout.icon, height: layout.icon)
                                            .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))
                                    }
                                    .frame(width: layout.cell, height: layout.cell)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onTapIndex(idx)
                                    }
                                } else {
                                    Color.clear
                                        .frame(width: layout.cell, height: layout.cell)
                                }
                            }
                        }
                    }
                }
                .padding(layout.pad)
                .background(
                    VisualEffectView(material: .sidebar, blending: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: layout.corner, style: .continuous))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
