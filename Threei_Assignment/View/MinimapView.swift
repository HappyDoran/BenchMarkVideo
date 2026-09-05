import SwiftUI

/// Top-down 미니맵. north-up 고정(월드 좌표 고정), 사용자 마커가 회전.
/// 맵 이미지는 auto-fit crop된 정사각형 — 뷰도 정사각형으로 쓴다.
/// `visibleRadius`를 주면 이미지를 스케일·이동해 카메라를 항상 중앙에 두고 반경 r(m)만 보인다 (오버레이용).
/// 창이 카메라를 따라 미끄러지므로 걸어 들어간 영역은 나타나고 벗어난 영역은 사라진다 — 격자 데이터는 그대로 남는다.
/// nil이면 관측 영역 전체를 맞춰 보인다 (전체화면용).
struct MinimapView: View {
    let snapshot: MinimapSnapshot?
    var visibleRadius: Float? = nil
    /// 전체화면 팬·줌 (visibleRadius가 nil일 때만 적용). 오버레이 창은 카메라 추종 변환이 우선.
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Color.black.opacity(0.55)

                if let snapshot {
                    let (scale, offset) = mapTransform(snapshot, side: side)
                    if let cgImage = snapshot.image {
                        Image(decorative: cgImage, scale: 1)
                            .interpolation(.none)   // 셀 경계 선명하게
                            .resizable()
                            .frame(width: side, height: side)
                            .scaleEffect(scale, anchor: .topLeading)
                            .offset(x: offset.x, y: offset.y)
                    }
                    Canvas { context, size in
                        drawTrajectory(snapshot, context: &context, size: size, scale: scale, offset: offset)
                        drawMarker(snapshot, context: &context, size: size, scale: scale, offset: offset)
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

    /// 이미지를 (scale, offset)으로 그리면 카메라가 뷰 중앙에 오고 한 변이 2r(m)이 된다.
    /// visibleRadius가 nil이면 사용자 팬·줌(기본 항등) — 전체화면 제스처가 같은 변환 경로를 탄다.
    private func mapTransform(_ snapshot: MinimapSnapshot, side: CGFloat) -> (CGFloat, CGPoint) {
        guard let visibleRadius else {
            return (zoomScale, CGPoint(x: panOffset.width, y: panOffset.height))
        }
        let scale = CGFloat(snapshot.cropSideMeters / (2 * visibleRadius))
        let n = snapshot.normalizedPoint(snapshot.cameraPosition)
        return (scale, CGPoint(x: side * (0.5 - n.x * scale), y: side * (0.5 - n.y * scale)))
    }

    private func point(_ world: SIMD2<Float>, _ snapshot: MinimapSnapshot, _ size: CGSize,
                       scale: CGFloat, offset: CGPoint) -> CGPoint {
        let n = snapshot.normalizedPoint(world)
        return CGPoint(x: n.x * size.width * scale + offset.x, y: n.y * size.height * scale + offset.y)
    }

    private func drawTrajectory(_ snapshot: MinimapSnapshot, context: inout GraphicsContext, size: CGSize,
                                scale: CGFloat, offset: CGPoint) {
        guard snapshot.trajectory.count > 1 else { return }
        var path = Path()
        path.move(to: point(snapshot.trajectory[0], snapshot, size, scale: scale, offset: offset))
        for p in snapshot.trajectory.dropFirst() {
            path.addLine(to: point(p, snapshot, size, scale: scale, offset: offset))
        }
        // 마지막 궤적점 → 현재 위치 연결
        path.addLine(to: point(snapshot.cameraPosition, snapshot, size, scale: scale, offset: offset))
        context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawMarker(_ snapshot: MinimapSnapshot, context: inout GraphicsContext, size: CGSize,
                            scale: CGFloat, offset: CGPoint) {
        let center = point(snapshot.cameraPosition, snapshot, size, scale: scale, offset: offset)

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
