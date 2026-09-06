import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    /// ARView(RealityKit 엔진) 생성은 메인 스레드를 수 초 블로킹 —
    /// 첫 프레임을 먼저 그리고 나서 마운트해 흰 런치 화면 체류를 없앤다.
    @State private var isARMounted = false

    var body: some View {
        Group {
            if !viewModel.isDeviceSupported {
                unsupportedView
            } else if let fatal = viewModel.fatalMessage {
                fatalErrorView(fatal)
            } else {
                scanScreen
            }
        }
        #if SCAN_DIAGNOSTICS
        .overlay(alignment: .topLeading) {
            ScanDebugView(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.top, 76)
        }
        #endif
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
                    if !viewModel.isMapExpanded {
                        // 반경 2m — 게임 미니맵식 근접 뷰 (사용자 결정 3 → 2).
                        // 배경은 실시간 mesh top-down, 마커·궤적은 캔버스. 넓은 맥락은 전체화면 담당.
                        MinimapView(snapshot: viewModel.snapshot, visibleRadius: 2,
                                    meshBackground: viewModel.minimapBackgroundMesh)
                            .frame(width: 160)
                            .onTapGesture { viewModel.openExpandedMap() }
                    }
                    Spacer()
                    controls
                }
            }
            .padding()

            if viewModel.isMapExpanded {
                ExpandedMapView(viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isMapExpanded)
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
