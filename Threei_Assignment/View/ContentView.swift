import Foundation
import simd
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var isMinimapExpanded = false
    /// 거리 측정 점(월드 xz, 최대 2개) — 전체화면에서 탭으로 지정, 세 번째 탭은 새 측정 시작.
    @State private var measurePoints: [SIMD2<Float>] = []
    /// 전체화면 2D 세계 창 — 중심(월드 xz)과 반경(m). 팬 = 중심 이동, 줌 = 반경 축소.
    /// nil이면 첫 스냅샷의 관측 영역으로 auto-fit 초기화.
    @State private var viewCenter: SIMD2<Float>?
    @State private var viewRadius: Float = 5
    @State private var baseCenter: SIMD2<Float>?
    @State private var baseRadius: Float?
    /// 전체화면 뷰어 모드 — 2D 미니맵 / 3D 점군. 측정 상태(measurePoints)는 두 모드가 공유.
    @State private var mapViewMode: MapViewMode = .map2D

    enum MapViewMode: String, CaseIterable {
        case map2D = "2D"
        case cloud3D = "3D"
    }
    /// ARView(RealityKit 엔진) 생성은 메인 스레드를 수 초 블로킹 —
    /// 첫 프레임을 먼저 그리고 나서 마운트해 흰 런치 화면 체류를 없앤다.
    @State private var isARMounted = false

    var body: some View {
        if !viewModel.isDeviceSupported {
            unsupportedView
        } else if let fatal = viewModel.fatalMessage {
            fatalErrorView(fatal)
        } else {
            scanScreen
        }
    }

    // MARK: - 메인 스캔 화면

    private var scanScreen: some View {
        ZStack {
            if isARMounted {
                ARPreviewView(onSessionReady: { viewModel.attach(session: $0) },
                              showMesh: viewModel.state == .scanning)   // mesh 보임 = 지금 기록 중. 재구성은 계속 돌아 재개 시 즉시 표시
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // 첫 스냅샷 전 = 렌더러·카메라 워밍업 구간
            if viewModel.snapshot == nil {
                ProgressView("카메라 준비 중…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            // 레이아웃 문법: 정보(상태·경고)는 상단 중앙, 조작(버튼)은 우하단 엄지 범위,
            // 미니맵은 좌하단 — 스캔 시선(중앙~상단)을 가리지 않는다 (최종결과물 영상과 같은 배치).
            VStack {
                statusBar
                Spacer()
                HStack(alignment: .bottom) {
                    if !isMinimapExpanded {
                        // 반경 2m — 게임 미니맵식 근접 뷰 (사용자 결정 3 → 2).
                        // 배경은 실시간 mesh top-down, 마커·궤적은 캔버스. 넓은 맥락은 전체화면 담당.
                        MinimapView(snapshot: viewModel.snapshot, visibleRadius: 2,
                                    meshBackground: viewModel.liveMesh)
                            .frame(width: 160)
                            .onTapGesture { isMinimapExpanded = true }
                    }
                    Spacer()
                    controls
                }
            }
            .padding()

            if isMinimapExpanded {
                expandedMinimap
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isMinimapExpanded)
        .task {
            // 첫 프레임 렌더 후에 ARView 마운트 — RealityKit 초기화가 런치 화면을 막지 않게
            isARMounted = true
        }
    }

    /// 상단 중앙 정보 스택 — 상태 한 줄 + 경고·안내 배지. 미니맵과 폭 경쟁 없음.
    private var statusBar: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateBadge.color)
                    .frame(width: 8, height: 8)
                Text(stateBadge.label)
                    .font(.footnote.weight(.semibold))
                if let snapshot = viewModel.snapshot, snapshot.totalPoints > 0 {
                    Text("·  \(snapshot.totalPoints.formatted()) pts  ·  \(snapshot.occupiedCellCount) cells")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())

            // 초기화 직후 스캔 시작 → 첫 mesh 앵커까지 약 1초 공백에 이름을 붙임
            if viewModel.state == .scanning && !viewModel.isMeshReady {
                meshLoadingBadge
            }
            if let warning = viewModel.trackingMessage {
                warningBadge(warning, icon: "exclamationmark.triangle.fill")
            }
            if viewModel.isInterrupted {
                warningBadge("세션이 중단되었습니다", icon: "pause.circle.fill")
            }
        }
    }

    private var meshLoadingBadge: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("주변 인식 중…")
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func warningBadge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
    }

    private var stateBadge: (label: String, color: Color) {
        switch viewModel.state {
        case .ready: ("대기", .gray)
        case .scanning: ("스캔 중", .green)
        case .paused: ("일시정지", .orange)
        }
    }

    /// 우하단 세로 스택 — 오른손 엄지 도달 범위. 주 동작이 아래(가까운 쪽), 초기화는 위.
    private var controls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            switch viewModel.state {
            case .ready:
                controlButton("스캔 시작", icon: "record.circle", prominent: true) {
                    viewModel.start()
                }
            case .scanning:
                resetButton
                controlButton("일시정지", icon: "pause.fill") { viewModel.pause() }
            case .paused:
                resetButton
                controlButton("재개", icon: "play.fill", prominent: true) { viewModel.start() }
            }
        }
    }

    private var resetButton: some View {
        controlButton("초기화", icon: "arrow.counterclockwise") { viewModel.reset() }
    }

    private func controlButton(_ title: String, icon: String,
                               prominent: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(prominent ? AnyShapeStyle(.blue) : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private var expandedMinimap: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { closeExpandedMinimap() }
            VStack(spacing: 12) {
                Picker("보기", selection: $mapViewMode) {
                    ForEach(MapViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                if mapViewMode == .map2D {
                    GeometryReader { geo in
                        let side = geo.size.width
                        ZStack {
                            Color.black.opacity(0.55)
                            if let mesh = viewModel.liveMesh, !mesh.positions.isEmpty,
                               let center = viewCenter {
                                // 오버레이 미니맵과 같은 mesh top-down — 격자 비트맵의 도트·검정 블록 없음
                                MeshTopDownView(mesh: mesh, cameraXZ: center, visibleRadius: viewRadius)
                                map2DOverlay(side: side)   // 세계 창 매핑 — mesh 카메라와 동일 기준
                            } else {
                                // mesh 전(스캔 극초반) 격자 fallback — auto-fit 매핑이라
                                // 세계 창 오버레이·측정과 기준이 달라 자체 마커·궤적만 쓴다
                                MinimapView(snapshot: viewModel.snapshot)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25)))
                        .onTapGesture(coordinateSpace: .local) { p in
                            addMeasurePoint(p, side: side)
                        }
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if baseRadius == nil { baseRadius = viewRadius }
                                    viewRadius = min(max((baseRadius ?? viewRadius) / Float(value), 0.5), 20)
                                }
                                .onEnded { _ in baseRadius = nil }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard let center = viewCenter else { return }
                                    if baseCenter == nil { baseCenter = center }
                                    let metersPerPoint = 2 * viewRadius / Float(side)
                                    viewCenter = (baseCenter ?? center) - SIMD2(
                                        Float(value.translation.width) * metersPerPoint,
                                        Float(value.translation.height) * metersPerPoint)
                                }
                                .onEnded { _ in baseCenter = nil }
                        )
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                } else if let cloud = viewModel.pointCloud {
                    // 2D와 같은 정사각 프레임 — 모드 전환 시 피커·버튼 위치가 흔들리지 않는다.
                    // mesh는 liveMesh(주기 갱신) 공용 — 별도 export 없음.
                    PointCloudViewerView(cloud: cloud, mesh: viewModel.liveMesh,
                                         measurePoints: $measurePoints)
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
                            expandedButtonLabel("내보내기", icon: "square.and.arrow.up")
                        }
                    }
                    Button {
                        closeExpandedMinimap()
                    } label: {
                        expandedButtonLabel("닫기", icon: "xmark")
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            viewModel.prepareExport()
            viewModel.preparePointCloud()   // 3D 전환 시 바로 보이게 미리 준비
            autoFitWorldWindowIfNeeded()
        }
        // 첫 스냅샷 전에 열렸으면 스냅샷 도착 시 auto-fit 재시도 — onAppear 한 번으로는 영구 nil
        .onChange(of: viewModel.snapshot == nil) { _, _ in autoFitWorldWindowIfNeeded() }
        .onChange(of: mapViewMode) { _, mode in
            if mode == .cloud3D { viewModel.preparePointCloud() }  // 최신 격자 반영
        }
    }

    /// 세계 창 auto-fit 초기화: 관측 영역 중심 + 반경 (스냅샷 crop 기반). 이미 설정돼 있으면 유지.
    private func autoFitWorldWindowIfNeeded() {
        guard viewCenter == nil, let snapshot = viewModel.snapshot else { return }
        viewCenter = snapshot.worldPoint(normalized: CGPoint(x: 0.5, y: 0.5))
        viewRadius = max(snapshot.cropSideMeters / 2, 2)
    }

    private func expandedButtonLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
    }

    private func closeExpandedMinimap() {
        isMinimapExpanded = false
        measurePoints = []
        viewCenter = nil; viewRadius = 5
        baseCenter = nil; baseRadius = nil
        mapViewMode = .map2D
    }

    // MARK: - 거리 측정 (전체화면 전용 — 세계 창 매핑: 뷰 좌표 ↔ 중심·반경 기준 월드 좌표)

    private var measureLabel: String {
        switch measurePoints.count {
        case 2: String(format: "거리 %.2f m", simd_distance(measurePoints[0], measurePoints[1]))
        case 1: "두 번째 점을 탭"
        default: "두 점을 탭해 거리 측정"
        }
    }

    /// 월드 (x, z) → 전체화면 2D 뷰 좌표 (세계 창: 중심 viewCenter, 반경 viewRadius).
    private func worldToView(_ w: SIMD2<Float>, side: CGFloat) -> CGPoint? {
        guard let center = viewCenter else { return nil }
        let s = side / CGFloat(2 * viewRadius)
        return CGPoint(x: side / 2 + CGFloat(w.x - center.x) * s,
                       y: side / 2 + CGFloat(w.y - center.y) * s)
    }

    private func addMeasurePoint(_ p: CGPoint, side: CGFloat) {
        // mesh 배경(세계 창 매핑)에서만 유효 — 격자 fallback은 다른 매핑이라 측정을 받지 않는다
        guard side > 0, let center = viewCenter,
              viewModel.liveMesh?.positions.isEmpty == false else { return }
        let metersPerPoint = 2 * viewRadius / Float(side)
        let world = center + SIMD2(Float(p.x - side / 2) * metersPerPoint,
                                   Float(p.y - side / 2) * metersPerPoint)
        measurePoints = measurePoints.count >= 2 ? [world] : measurePoints + [world]
    }

    /// 전체화면 2D 오버레이 — 궤적·마커·측정 (mesh 배경 위, 세계 창 매핑).
    private func map2DOverlay(side: CGFloat) -> some View {
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
            let points = measurePoints.compactMap { worldToView($0, side: side) }
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

    // MARK: - 예외 화면

    private var unsupportedView: some View {
        infoScreen(icon: "sensor.tag.radiowaves.forward.fill",
                   title: "지원되지 않는 기기",
                   message: "이 앱은 LiDAR 센서가 필요합니다.\niPhone 12 Pro 이상 Pro 모델 또는\niPad Pro(2020 이상)에서 실행해 주세요.")
    }

    private func fatalErrorView(_ message: String) -> some View {
        infoScreen(icon: "exclamationmark.octagon.fill",
                   title: "실행할 수 없습니다",
                   message: message) {
            if viewModel.isPermissionDenied {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("설정 열기", destination: url)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button("다시 시도") { viewModel.retry() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func infoScreen(icon: String, title: String, message: String,
                            @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            extra()
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
}
