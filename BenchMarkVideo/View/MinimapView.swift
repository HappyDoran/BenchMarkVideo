import SwiftUI

/// Top-down 미니맵. north-up 고정(월드 좌표 고정), 사용자 마커가 회전.
/// 맵 이미지는 auto-fit crop된 정사각형 — 뷰도 정사각형으로 쓴다.
/// `visibleRadius`를 주면 이미지를 스케일·이동해 카메라를 항상 중앙에 두고 반경 r(m)만 보인다 (오버레이용).
/// 창이 카메라를 따라 미끄러지므로 걸어 들어간 영역은 나타나고 벗어난 영역은 사라진다 — 격자 데이터는 그대로 남는다.
/// nil이면 관측 영역 전체를 맞춰 보인다 (전체화면용).
struct MinimapView: View {
    let snapshot: MinimapSnapshot?
    var visibleRadius: Float? = nil
    /// 있으면 격자 이미지 대신 정점 색 mesh top-down 렌더를 배경으로 (오버레이 전용).
    /// 마커·궤적 캔버스의 카메라 중심·반경 매핑이 mesh 직교 카메라와 같아 그대로 정합된다.
    var meshBackground: ColoredMesh? = nil

    var body: some View {
        GeometryReader { geo in
            // 정사각 레이아웃의 너비를 배경 이미지와 오버레이의 공통 한 변으로 사용한다.
            let side = geo.size.width
            ZStack {
                Color.black.opacity(0.55)

                if let snapshot {
                    // 카메라 중심 근접 창 또는 전체 crop에 맞는 공통 scale·offset을 계산한다.
                    let (scale, offset) = mapTransform(snapshot, side: side)
                    if let meshBackground, let visibleRadius, !meshBackground.positions.isEmpty {
                        MeshTopDownView(mesh: meshBackground,
                                        cameraXZ: snapshot.cameraPosition,
                                        visibleRadius: visibleRadius)
                    } else if let cgImage = snapshot.image {
                        Image(decorative: cgImage, scale: 1)
                            .interpolation(.medium)   // 셀 경계를 부드럽게 — .none은 도트맵처럼 보임 (실기기 피드백)
                            .resizable()
                            .frame(width: side, height: side)
                            .scaleEffect(scale, anchor: .topLeading)
                            .offset(x: offset.x, y: offset.y)
                    }
                    Canvas { context, size in
                        // 배경과 같은 좌표 변환으로 경로와 사용자 방향 마커를 겹친다.
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
    /// visibleRadius가 nil이면 항등 (전체화면 fallback — 팬·줌은 ExpandedMapView의 세계 창이 담당).
    private func mapTransform(_ snapshot: MinimapSnapshot, side: CGFloat) -> (CGFloat, CGPoint) {
        // 전체 지도를 표시할 때는 snapshot crop 이미지를 변형하지 않는다.
        guard let visibleRadius else { return (1, .zero) }
        // crop 실제 길이를 목표 지름 2r로 확대하고 카메라 정규화 위치가 화면 중앙에 오게 이동한다.
        let scale = CGFloat(snapshot.cropSideMeters / (2 * visibleRadius))
        let n = snapshot.normalizedPoint(snapshot.cameraPosition)
        return (scale, CGPoint(x: side * (0.5 - n.x * scale), y: side * (0.5 - n.y * scale)))
    }

    private func point(_ world: SIMD2<Float>, _ snapshot: MinimapSnapshot, _ size: CGSize,
                       scale: CGFloat, offset: CGPoint) -> CGPoint {
        // 월드 xz를 snapshot crop 비율로 바꾼 뒤 배경과 동일한 확대·이동을 적용한다.
        let n = snapshot.normalizedPoint(world)
        return CGPoint(x: n.x * size.width * scale + offset.x, y: n.y * size.height * scale + offset.y)
    }

    private func drawTrajectory(_ snapshot: MinimapSnapshot, context: inout GraphicsContext, size: CGSize,
                                scale: CGFloat, offset: CGPoint) {
        // 선분을 만들 수 없는 경로 0·1개 상태에서는 그리기를 생략한다.
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
        // 카메라 월드 위치를 현재 미니맵 창의 화면 중심 좌표로 변환한다.
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
