import SwiftUI

/// Top-down 미니맵. north-up 고정(월드 좌표 고정), 사용자 마커가 회전.
/// 맵 이미지는 auto-fit crop된 정사각형 — 뷰도 정사각형으로 쓴다.
struct MinimapView: View {
    let snapshot: MinimapSnapshot?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55)

                if let snapshot {
                    if let cgImage = snapshot.image {
                        Image(decorative: cgImage, scale: 1)
                            .interpolation(.none)   // 셀 경계 선명하게
                            .resizable()
                    }
                    Canvas { context, size in
                        drawTrajectory(snapshot, context: &context, size: size)
                        drawMarker(snapshot, context: &context, size: size)
                    }
                } else {
                    Text("스캔 대기 중")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25)))
    }

    private func point(_ world: SIMD2<Float>, _ snapshot: MinimapSnapshot, _ size: CGSize) -> CGPoint {
        let n = snapshot.normalizedPoint(world)
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    private func drawTrajectory(_ snapshot: MinimapSnapshot, context: inout GraphicsContext, size: CGSize) {
        guard snapshot.trajectory.count > 1 else { return }
        var path = Path()
        path.move(to: point(snapshot.trajectory[0], snapshot, size))
        for p in snapshot.trajectory.dropFirst() {
            path.addLine(to: point(p, snapshot, size))
        }
        // 마지막 궤적점 → 현재 위치 연결
        path.addLine(to: point(snapshot.cameraPosition, snapshot, size))
        context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawMarker(_ snapshot: MinimapSnapshot, context: inout GraphicsContext, size: CGSize) {
        let center = point(snapshot.cameraPosition, snapshot, size)

        // 시야 부채꼴 (바라보는 방향 표시 보조)
        let heading = CGFloat(snapshot.cameraHeading)
        let fov: CGFloat = .pi / 3
        var cone = Path()
        cone.move(to: center)
        // 화면 각도: 위(-y) 기준 시계방향 heading → 표준 각도 = heading - π/2
        cone.addArc(center: center, radius: 22,
                    startAngle: .radians(heading - .pi / 2 - fov / 2),
                    endAngle: .radians(heading - .pi / 2 + fov / 2),
                    clockwise: false)
        cone.closeSubpath()
        context.fill(cone, with: .color(.yellow.opacity(0.25)))

        // 방향 삼각형
        var triangle = Path()
        triangle.move(to: CGPoint(x: 0, y: -7))
        triangle.addLine(to: CGPoint(x: 5, y: 6))
        triangle.addLine(to: CGPoint(x: -5, y: 6))
        triangle.closeSubpath()
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: heading)
        context.fill(triangle.applying(transform), with: .color(.yellow))
    }
}
