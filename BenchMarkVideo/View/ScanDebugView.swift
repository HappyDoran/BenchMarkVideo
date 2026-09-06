#if SCAN_DIAGNOSTICS
import Foundation
import SwiftUI

/// 녹화에 함께 남기는 진단 패널. 센서/GPU 정확성을 자동으로 합격 판정하지 않는다.
struct ScanDebugView: View {
    @Bindable var viewModel: ScanViewModel
    @State private var expanded = true
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(expanded ? "진단 D1 접기" : "진단 D1 열기") { expanded.toggle() }
                Spacer()
                Button("구간 #\(viewModel.diagnosticMarker + 1)") { viewModel.markDiagnosticSection() }
            }
            .font(.caption.bold())
            if expanded {
                // 빌드 구성은 컴파일 조건으로 판정 — Release + SCAN_DIAGNOSTICS 계측 빌드를 녹화에서 구분한다.
                #if DEBUG
                Text("Debug(-Onone) · 진단 ON")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                #else
                Text("Release(-O) · 진단 ON · 제출 빌드는 진단 OFF")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                #endif
                Picker("진단 항목", selection: $page) {
                    Text("갱신").tag(0)
                    Text("부하").tag(1)
                    Text("좌표·기록").tag(2)
                }
                .pickerStyle(.segmented)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    let d = viewModel.diagnostics
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "녹화 시계 %.1fs · 구간 #%d · 세대 %d", now - viewModel.diagnosticStarted,
                                    viewModel.diagnosticMarker, d.generation))
                        Text("제어 \(stateLabel) / 처리 \(d.gate)")
                        Text("계측 수신 \(age(d.timestamp, now)) · \(viewModel.isInterrupted ? "세션 중단" : (viewModel.trackingMessage ?? "트래킹 경고 없음"))")
                        if page == 0 {
                            Text("표시 \(displayLabel) · 격자 UI 수신 \(age(viewModel.diagnosticSnapshotTime, now))")
                            Text("mesh UI 수신 \(age(viewModel.diagnosticMeshTime, now)) · 버전 \(viewModel.liveMesh?.version ?? 0)")
                            Text("mesh 원본 프레임 \(age(viewModel.liveMesh?.diagnosticSourceTimestamp ?? 0, now)) · 세대 \(viewModel.liveMesh.map { String($0.diagnosticGeneration) } ?? "—")")
                            Text("누적 \(viewModel.snapshot?.totalPoints ?? 0)점 / 관측 \(viewModel.snapshot?.occupiedCellCount ?? 0)셀")
                            Text("최근 처리 프레임: 유효 \(d.sampledPoints)점 → 격자 \(d.acceptedPoints)점")
                            Text("깊이 \(d.depthSource) · 처리 프레임 시각 \(age(d.frameTimestamp, now))")
                            Text(String(format: "연속 누적 허용 %.1fs · 최장 %.1fs", d.continuousSeconds, d.longestSeconds))
                        } else if page == 1 {
                            let fps = FPSMonitor.shared
                            Text(String(format: "DisplayLink %.1fHz / 최대 간격 %.1fms", fps.average, fps.maximumGapMs))
                            Text("DisplayLink 측정 \(age(fps.measuredAt, now)) · 3초 창")
                            Text(String(format: "콜백 평균 %.1f / 최대 %.1fms", d.callbackMeanMs, d.callbackMaxMs))
                            Text(String(format: "콜백 3초 창 p50 %.1f / p95 %.1fms", d.callbackP50Ms, d.callbackP95Ms))
                            Text("약 0.5초 창 수신 \(d.receivedFrames) / 처리 \(d.processedFrames)프레임")
                            Text("누적 수신 \(d.totalReceivedFrames) / 깊이 처리 \(d.totalDepthFrames)프레임")
                            Text(String(format: "최근 mesh CPU 빌드 %.1fms", viewModel.liveMesh?.diagnosticBuildMs ?? 0))
                            Text(d.memoryMB >= 0 ? String(format: "메모리 %.1f / 앱 실행 피크 %.1fMB", d.memoryMB, d.peakMemoryMB) : "메모리 측정 대기/실패")
                            Text("앵커 \(d.anchors) · 정점 \(viewModel.liveMesh?.positions.count ?? 0) · 복셀 항목 \(d.voxelEntries)")
                            Text("발열: \(thermalLabel)")
                        } else {
                            Text(String(format: "월드 x %.2f / y %.2f / z %.2fm", d.position.x, d.position.y, d.position.z))
                            Text(String(format: "방향 %.1f° · 위 = 월드 −z", (viewModel.snapshot?.cameraHeading ?? 0) * 180 / .pi))
                            Text(d.originY.map { String(format: "시작 y %.2fm · 현재 상대 y %.2fm", $0, d.position.y - $0) } ?? "시작 높이 미확정")
                            ForEach(Array(viewModel.diagnosticEvents.enumerated()), id: \.offset) { _, event in
                                Text(event).lineLimit(2)
                            }
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                }
                Toggle("격자만 보기 (오버레이 비교)", isOn: $viewModel.diagnosticGridOnly)
                    .font(.caption)
                    .onChange(of: viewModel.diagnosticGridOnly) { _, enabled in
                        viewModel.markDiagnosticEvent(enabled ? "격자 비교 켬" : "mesh 표시 복귀")
                    }
                Text("UI 수신 ≠ GPU 표시 완료 · 연속 시간은 보류/프레임 공백 시 끊김")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(10)
        .foregroundStyle(.white)
        .tint(.cyan)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 350)
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .ready: "대기"
        case .scanning: "스캔"
        case .paused: "일시정지"
        }
    }

    private var displayLabel: String {
        viewModel.diagnosticGridOnly || viewModel.liveMesh?.positions.isEmpty != false ? "격자" : "mesh"
    }

    private func age(_ time: TimeInterval, _ now: TimeInterval) -> String {
        time > 0 ? String(format: "%.1f초 전", max(0, now - time)) : "없음"
    }

    private var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "정상"
        case .fair: "상승"
        case .serious: "높음"
        case .critical: "매우 높음"
        @unknown default: "알 수 없음"
        }
    }
}
#endif
