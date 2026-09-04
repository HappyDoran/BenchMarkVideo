import Foundation
import simd
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var isMinimapExpanded = false
    /// 거리 측정 점(월드 xz, 최대 2개) — 전체화면에서 탭으로 지정, 세 번째 탭은 새 측정 시작.
    @State private var measurePoints: [SIMD2<Float>] = []
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

            VStack {
                HStack(alignment: .top) {
                    statusBar
                    Spacer()
                    if !isMinimapExpanded {
                        // ponytail: 반경 6m 고정. 팬·줌을 넣으면 이 값이 줌 상태가 된다.
                        MinimapView(snapshot: viewModel.snapshot, visibleRadius: 6)
                            .frame(width: 150)
                            .onTapGesture { isMinimapExpanded = true }
                    }
                }
                Spacer()
                controls
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

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

    private var controls: some View {
        HStack(spacing: 16) {
            switch viewModel.state {
            case .ready:
                controlButton("스캔 시작", icon: "record.circle", prominent: true) {
                    viewModel.start()
                }
            case .scanning:
                controlButton("일시정지", icon: "pause.fill") { viewModel.pause() }
                resetButton
            case .paused:
                controlButton("재개", icon: "play.fill", prominent: true) { viewModel.start() }
                resetButton
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
                GeometryReader { geo in
                    MinimapView(snapshot: viewModel.snapshot)
                        .overlay { measureOverlay(side: geo.size.width) }
                        .onTapGesture(coordinateSpace: .local) { p in
                            addMeasurePoint(p, side: geo.size.width)
                        }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    if let snapshot = viewModel.snapshot {
                        Text(String(format: "관측 면적 %.1f m²", snapshot.observedAreaM2))
                    }
                    Text(measureLabel)
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 16) {
                    if let url = viewModel.exportURL {
                        ShareLink(item: url) {
                            Label("내보내기", systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Button {
                        closeExpandedMinimap()
                    } label: {
                        Label("닫기", systemImage: "xmark")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(24)
        }
        .onAppear { viewModel.prepareExport() }
    }

    private func closeExpandedMinimap() {
        isMinimapExpanded = false
        measurePoints = []
    }

    // MARK: - 거리 측정 (전체화면 전용 — 항등 변환이라 뷰 좌표/side = 정규화 좌표)

    private var measureLabel: String {
        switch measurePoints.count {
        case 2: String(format: "거리 %.2f m", simd_distance(measurePoints[0], measurePoints[1]))
        case 1: "두 번째 점을 탭"
        default: "두 점을 탭해 거리 측정"
        }
    }

    private func addMeasurePoint(_ p: CGPoint, side: CGFloat) {
        guard side > 0, let snapshot = viewModel.snapshot else { return }
        let world = snapshot.worldPoint(normalized: CGPoint(x: p.x / side, y: p.y / side))
        measurePoints = measurePoints.count >= 2 ? [world] : measurePoints + [world]
    }

    private func measureOverlay(side: CGFloat) -> some View {
        Canvas { context, _ in
            guard let snapshot = viewModel.snapshot else { return }
            let points = measurePoints.map { w -> CGPoint in
                let n = snapshot.normalizedPoint(w)
                return CGPoint(x: n.x * side, y: n.y * side)
            }
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
