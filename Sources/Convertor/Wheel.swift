import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let tangerine = Color(red: 1.0, green: 0.31, blue: 0.0)
}

/// State for the wheel that pops up under the cursor mid-drag.
final class WheelModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var actions: [Action] = []
    @Published private(set) var icon = NSImage()
    @Published var hovered: Int?
    @Published var visible = false
    @Published var mode: Mode = .convert {
        didSet {
            guard mode != oldValue else { return }
            hovered = nil
            actions = Catalog.actions(for: urls, mode: mode)
        }
    }

    var onPerform: ((Action, [URL]) -> Void)?

    func load(_ urls: [URL], mode: Mode) {
        self.urls = urls
        let workspace = NSWorkspace.shared
        let icon: NSImage? = urls.count == 1
            ? workspace.icon(forFile: urls[0].path)
            : workspace.icon(forFiles: urls.map(\.path))
        self.icon = icon ?? NSImage()
        hovered = nil
        self.mode = mode
        actions = Catalog.actions(for: urls, mode: mode)
    }
}

enum WheelGeometry {
    static let outer: CGFloat = 120
    static let inner: CGFloat = 50
    static let barHeight: CGFloat = 44
    static let captionHeight: CGFloat = 34
    static let size = CGSize(width: 340, height: barHeight + outer * 2 + 24 + captionHeight)
    static let center = CGPoint(x: size.width / 2, y: barHeight + outer + 12)

    /// Centre angle of segment `index`, in degrees, clockwise from 12 o'clock (y points down).
    static func angle(of index: Int, count: Int) -> Double {
        -90 + Double(index) * 360 / Double(count)
    }

    /// Which segment a point (in the wheel view's coordinates) falls on; nil in the hub or outside.
    static func segment(at point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= inner, radius <= outer + 36 else { return nil }
        let step = 360 / Double(count)
        var degrees = atan2(Double(dy), Double(dx)) * 180 / .pi + 90 + step / 2
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return min(count - 1, Int(degrees / step))
    }
}

/// One slice of the donut, inset by `inset` so a stroke of twice that width rounds its corners.
struct RingSegment: Shape {
    let index: Int
    let count: Int
    var inset: CGFloat = 5
    var gap: CGFloat = 5   // points between neighbouring tiles

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = WheelGeometry.outer - inset, inner = WheelGeometry.inner + inset
        let step = 360 / Double(count)
        let middle = Double((outer + inner) / 2)
        let gapDegrees = count > 1 ? Double(gap + inset * 2) / middle * 180 / .pi : 0
        let start = WheelGeometry.angle(of: index, count: count) - step / 2 + gapDegrees / 2
        let end = start + step - gapDegrees
        let samples = max(8, Int(end - start) / 2)

        func point(_ radius: CGFloat, _ degrees: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: center.x + radius * CGFloat(cos(radians)), y: center.y + radius * CGFloat(sin(radians)))
        }

        var path = Path()
        for i in 0...samples {
            let p = point(outer, start + (end - start) * Double(i) / Double(samples))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for i in (0...samples).reversed() {
            path.addLine(to: point(inner, start + (end - start) * Double(i) / Double(samples)))
        }
        path.closeSubpath()
        return path
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    private var hoveredAction: Action? {
        model.hovered.flatMap { model.actions.indices.contains($0) ? model.actions[$0] : nil }
    }

    var body: some View {
        ZStack {
            ModeBar(mode: model.mode)
                .position(x: WheelGeometry.size.width / 2, y: WheelGeometry.barHeight / 2)

            wheel
                .frame(width: WheelGeometry.outer * 2, height: WheelGeometry.outer * 2)
                .position(WheelGeometry.center)

            Text(hoveredAction?.caption ?? (model.actions.isEmpty ? " " : "Drop on a segment · centre cancels"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hoveredAction == nil ? .secondary : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
                .position(x: WheelGeometry.size.width / 2,
                          y: WheelGeometry.center.y + WheelGeometry.outer + 12 + WheelGeometry.captionHeight / 2)
        }
        .frame(width: WheelGeometry.size.width, height: WheelGeometry.size.height)
        .scaleEffect(model.visible ? 1 : 0.7, anchor: UnitPoint(x: 0.5, y: WheelGeometry.center.y / WheelGeometry.size.height))
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: model.visible)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(model: model))
    }

    private var wheel: some View {
        let count = model.actions.count
        let labelRadius = (WheelGeometry.inner + WheelGeometry.outer) / 2
        let side = WheelGeometry.outer * 2
        let idle = Color(nsColor: .controlBackgroundColor).opacity(0.9)

        return ZStack {
            Circle()
                .fill(Color.clear)
                .frame(width: side + 14, height: side + 14)
                .glassEffect(.regular, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 18, y: 8)

            if count == 0 {
                Text("Nothing here for this file")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(y: -labelRadius)
            }

            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                let active = model.hovered == index
                let radians = WheelGeometry.angle(of: index, count: count) * .pi / 180
                let segment = RingSegment(index: index, count: count)
                let fill = active ? Color.tangerine : idle

                segment
                    .fill(fill)
                    .overlay(segment.stroke(fill, style: StrokeStyle(lineWidth: segment.inset * 2, lineJoin: .round)))
                    .shadow(color: .black.opacity(active ? 0.25 : 0.08), radius: active ? 6 : 2, y: 1)

                SegmentLabel(action: action, active: active, compact: count > 8)
                    .position(x: side / 2 + labelRadius * CGFloat(cos(radians)), y: side / 2 + labelRadius * CGFloat(sin(radians)))
                    .scaleEffect(active ? 1.06 : 1)
            }

            // The hub: file icon, or the hovered action's name like Tangerine.
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 4)
                if let action = hoveredAction {
                    Text(action.title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .padding(6)
                } else {
                    Image(nsImage: model.icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                if model.urls.count > 1 {
                    Text("\(model.urls.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.tangerine))
                        .offset(x: 22, y: -22)
                }
            }
            .frame(width: (WheelGeometry.inner - 6) * 2, height: (WheelGeometry.inner - 6) * 2)
        }
        .frame(width: side, height: side)
    }
}

private struct SegmentLabel: View {
    let action: Action
    let active: Bool
    let compact: Bool

    var body: some View {
        VStack(spacing: 3) {
            if !action.symbol.isEmpty {
                Image(systemName: action.symbol).font(.system(size: compact ? 11 : 13, weight: .semibold))
            }
            Text(action.title.uppercased())
                .font(.system(size: action.symbol.isEmpty ? 12 : (compact ? 7.5 : 8.5), weight: .bold))
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: compact ? 50 : 60)
        .foregroundStyle(active ? Color.white : Color.primary)
    }
}

private struct ModeBar: View {
    let mode: Mode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item.key).font(.system(size: 11, weight: .semibold))
                    Text(item.title).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(item == mode ? Color.white : Color.secondary)
                .background(Capsule().fill(item == mode ? Color.tangerine : Color.clear))
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: mode)
    }
}

/// Hit-tests the drag location against the donut, since the drop lands on the whole panel.
struct WheelDropDelegate: DropDelegate {
    let model: WheelModel

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { track(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: model.hovered == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) { model.hovered = nil }

    func performDrop(info: DropInfo) -> Bool {
        track(info)
        guard let index = model.hovered, model.actions.indices.contains(index) else { return false }
        model.onPerform?(model.actions[index], model.urls)
        return true
    }

    private func track(_ info: DropInfo) {
        let index = WheelGeometry.segment(at: info.location, count: model.actions.count)
        if model.hovered != index { model.hovered = index }
    }
}
