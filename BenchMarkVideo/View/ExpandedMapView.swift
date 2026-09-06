import Foundation
import simd
import SwiftUI

/// 전체화면 지도 — 2D 세계 창(팬·줌·거리 측정) / 3D 뷰어 / 내보내기. 상태는 전부 ViewModel.
/// 제스처 진행 중의 기준값(baseCenter·baseRadius)만 View의 임시 상태다.
struct ExpandedMapView: View {
    @Bindable var viewModel: ScanViewModel
    @State private var baseCenter: SIMD2<Float>?
    @State private var baseRadius: Float?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { viewModel.closeExpandedMap() }
            VStack(spacing: 12) {
                Picker("보기", selection: $viewModel.mapViewMode) {
                    ForEach(MapViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                if viewModel.mapViewMode == .map2D {
                    map2D
                } else if let cloud = viewModel.pointCloud {
                    // 2D와 같은 정사각 프레임 — 모드 전환 시 피커·버튼 위치가 흔들리지 않는다.
                    // mesh는 3D 진입 시점 고정본 — 보는 중 교체되면 카메라 리셋·공간 뒤틀림.
                    PointCloudViewerView(cloud: cloud, mesh: viewModel.expandedMesh,
                                         measurePoints: $viewModel.measurePoints)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView("점군 준비 중…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }

                VStack(spacing: 2) {
                    if let snapshot = viewModel.snapshot {
                        Text(String(format: "관측 면적 %.1f m²", snapshot.observedAreaM2))
                    }
                    Text(measureLabel)
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 12) {
                    if let url = viewModel.exportURL {
                        ShareLink(item: url) {
                            buttonLabel("내보내기", icon: "square.and.arrow.up")
                        }
                    }
                    Button {
                        viewModel.closeExpandedMap()
                    } label: {
                        buttonLabel("닫기", icon: "xmark")
                    }
                }
            }
            .padding(24)
        }
    }

    private var map2D: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Color.black.opacity(0.55)
                if let mesh = viewModel.liveMesh, !mesh.positions.isEmpty,
                   let center = viewModel.viewCenter {
                    // 오버레이 미니맵과 같은 mesh top-down — 격자 비트맵의 도트·검정 블록 없음
                    MeshTopDownView(mesh: mesh, cameraXZ: center, visibleRadius: viewModel.viewRadius)
                    overlay(side: side)   // 세계 창 매핑 — mesh 카메라와 동일 기준
                } else {
                    // mesh 전(스캔 극초반) 격자 fallback — auto-fit 매핑이라
                    // 세계 창 오버레이·측정과 기준이 달라 자체 마커·궤적만 쓴다
                    MinimapView(snapshot: viewModel.snapshot)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25)))
            .onTapGesture(coordinateSpace: .local) { p in
                if side > 0, let world = viewToWorld(p, side: side) {
                    viewModel.addMeasurePoint(world: world)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if baseRadius == nil { baseRadius = viewModel.viewRadius }
                        viewModel.zoomWorldWindow(radius: (baseRadius ?? viewModel.viewRadius) / Float(value))
                    }
                    .onEnded { _ in baseRadius = nil }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard let center = viewModel.viewCenter else { return }
                        if baseCenter == nil { baseCenter = center }
                        let metersPerPoint = 2 * viewModel.viewRadius / Float(side)
                        viewModel.panWorldWindow(to: (baseCenter ?? center) - SIMD2(
                            Float(value.translation.width) * metersPerPoint,
                            Float(value.translation.height) * metersPerPoint))
                    }
                    .onEnded { _ in baseCenter = nil }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var measureLabel: String {
        let points = viewModel.measurePoints
        return switch points.count {
        case 2: String(format: "거리 %.2f m", simd_distance(points[0], points[1]))
        case 1: "두 번째 점을 탭"
        default: "두 점을 탭해 거리 측정"
        }
    }

    private func buttonLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
    }

    // MARK: - 세계 창 매핑: 뷰 좌표 ↔ 중심·반경 기준 월드 좌표

    /// 월드 (x, z) → 2D 뷰 좌표.
    private func worldToView(_ w: SIMD2<Float>, side: CGFloat) -> CGPoint? {
        guard let center = viewModel.viewCenter else { return nil }
        let s = side / CGFloat(2 * viewModel.viewRadius)
        return CGPoint(x: side / 2 + CGFloat(w.x - center.x) * s,
                       y: side / 2 + CGFloat(w.y - center.y) * s)
    }

    private func viewToWorld(_ p: CGPoint, side: CGFloat) -> SIMD2<Float>? {
        guard let center = viewModel.viewCenter else { return nil }
        let metersPerPoint = 2 * viewModel.viewRadius / Float(side)
        return center + SIMD2(Float(p.x - side / 2) * metersPerPoint,
                              Float(p.y - side / 2) * metersPerPoint)
    }

    /// 2D 오버레이 — 궤적·마커·측정 (mesh 배경 위, 세계 창 매핑).
    private func overlay(side: CGFloat) -> some View {
        Canvas { context, _ in
            guard let snapshot = viewModel.snapshot else { return }
            // 궤적
            let trail = (snapshot.trajectory + [snapshot.cameraPosition])
                .compactMap { worldToView($0, side: side) }
            if trail.count > 1 {
                var path = Path()
                path.move(to: trail[0])
                for p in trail.dropFirst() { path.addLine(to: p) }
                context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
            }
            // 마커 (방향 삼각형)
            if let c = worldToView(snapshot.cameraPosition, side: side) {
                var triangle = Path()
                triangle.move(to: CGPoint(x: 0, y: -7))
                triangle.addLine(to: CGPoint(x: 5, y: 6))
                triangle.addLine(to: CGPoint(x: -5, y: 6))
                triangle.closeSubpath()
                let transform = CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: CGFloat(snapshot.cameraHeading))
                context.fill(triangle.applying(transform), with: .color(.yellow))
            }
            // 측정 마커·선
            let points = viewModel.measurePoints.compactMap { worldToView($0, side: side) }
            if points.count == 2 {
                var line = Path()
                line.move(to: points[0])
                line.addLine(to: points[1])
                context.stroke(line, with: .color(.orange), lineWidth: 2)
            }
            for p in points {
                let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(.orange))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}
