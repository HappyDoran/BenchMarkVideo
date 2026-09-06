#if SCAN_DIAGNOSTICS
import Foundation
import os
import simd

/// 녹화 판독용 값. 시각은 모두 systemUptime 초, GPU 표시 완료를 뜻하지 않는다.
nonisolated struct ScanDiagnostics: Sendable {
    var timestamp: TimeInterval = 0
    var frameTimestamp: TimeInterval = 0
    var generation = 0
    var receivedFrames = 0
    var processedFrames = 0
    var sampledPoints = 0
    var acceptedPoints = 0
    var callbackMeanMs = 0.0
    var callbackMaxMs = 0.0
    /// 약 3초(깊이 처리 30프레임) 창 백분위. perf 로그와 같은 값, 창이 닫힐 때만 갱신.
    var callbackP50Ms = 0.0
    var callbackP95Ms = 0.0
    var totalReceivedFrames = 0
    var totalDepthFrames = 0
    var depthSource = "없음"
    var continuousSeconds = 0.0
    var longestSeconds = 0.0
    var gate = "프레임 대기"
    var position = SIMD3<Float>.zero
    var originY: Float?
    var anchors = 0
    var voxelEntries = 0
    var memoryMB = -1.0
    var peakMemoryMB = -1.0
}

/// 0.5초 창 합계만 보관. 프레임/샘플 배열을 무한히 쌓지 않는다.
nonisolated struct ScanDiagnosticWindow {
    private var start: TimeInterval?
    private var received = 0
    private var processed = 0
    private var sumMs = 0.0
    private var maxMs = 0.0
    private var previousAllowed: TimeInterval?
    private(set) var continuousSeconds = 0.0
    private(set) var longestSeconds = 0.0

    mutating func receive() { received += 1 }

    mutating func record(now: TimeInterval, callbackMs: Double, allowed: Bool) {
        if start == nil { start = now }
        processed += 1
        sumMs += callbackMs
        maxMs = max(maxMs, callbackMs)
        if allowed {
            if let previousAllowed, now >= previousAllowed, now - previousAllowed <= 0.5 {
                continuousSeconds += now - previousAllowed
            } else { continuousSeconds = 0 }
            previousAllowed = now
            longestSeconds = max(longestSeconds, continuousSeconds)
        } else {
            continuousSeconds = 0
            previousAllowed = nil
        }
    }

    mutating func publish(now: TimeInterval) -> (received: Int, processed: Int, mean: Double, max: Double)? {
        guard let start, now - start >= 0.5, processed > 0 else { return nil }
        let result = (received, processed, sumMs / Double(processed), maxMs)
        self.start = now
        received = 0; processed = 0; sumMs = 0; maxMs = 0
        return result
    }
}

/// 처리 큐 계측 — signpost, perf 로그, 0.5초 창 집계를 한 곳에. `scan.processing` 큐 전용.
/// 세션 매니저는 프레임마다 `frameReceived` / `begin` / `end` 세 지점만 호출한다.
nonisolated final class ScanDiagnosticsCollector {
    /// `end`에 넘길 프레임 문맥 — 값만 받는다 (`ARFrame` 보관 금지).
    struct FrameContext {
        var timestamp: TimeInterval
        var position: SIMD3<Float>
        var anchorCount: Int
        var gate: String
        var allowed: Bool
        var depthSource: String
        var result: FrameResult
        var totalPoints: Int
        var originY: Float?
        var voxelEntries: Int
        var generation: Int
    }

    struct Probe {
        fileprivate let signpost: OSSignpostIntervalState
        fileprivate let start: TimeInterval
    }

    private var window = ScanDiagnosticWindow()
    private var peakMB = -1.0
    private var p50 = 0.0
    private var p95 = 0.0
    private var receivedCount = 0
    /// 깊이 처리 프레임 수 — perf 로그 주기용.
    private var depthCount = 0
    /// 최근 처리 프레임 콜백 소요(ms), 60개 상한 — 3초 창 백분위 계산.
    private var callbackMs: [Double] = []
    /// DESIGN.md 10절: 콜백 처리 시간을 Instruments Points of Interest로 측정.
    private let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.doran.benchmarkvideo", category: .pointsOfInterest))
    /// perf 지표 — Logger라서 Xcode 미부착이어도 `log collect --device`로 사후 수집 가능.
    private let perfLog = Logger(subsystem: "com.doran.benchmarkvideo", category: "perf")

    func frameReceived() {
        window.receive()
        receivedCount += 1
    }

    func begin() -> Probe {
        Probe(signpost: signposter.beginInterval("frameCallback"),
              start: ProcessInfo.processInfo.systemUptime)
    }

    /// 창이 닫히면 발행할 값을 돌려준다.
    func end(_ probe: Probe, context: FrameContext) -> ScanDiagnostics? {
        signposter.endInterval("frameCallback", probe.signpost)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMs = (now - probe.start) * 1000
        callbackMs.append(elapsedMs)
        if callbackMs.count > 60 { callbackMs.removeFirst(callbackMs.count - 60) }
        window.record(now: now, callbackMs: elapsedMs, allowed: context.allowed)
        if context.allowed {
            depthCount += 1
            if depthCount % 30 == 0 {
                // 약 3초 창 단위 백분위 — 누적하면 초반 샘플이 지배해 후반 저하를 가리고,
                // 무제한 배열 재정렬이 측정 대상 자체를 느리게 한다. 로그 후 창을 비운다.
                let sorted = callbackMs.sorted()
                p50 = sorted[sorted.count / 2]
                p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                perfLog.info("""
                    n=\(self.depthCount) points/frame=\(context.result.sampledPoints) \
                    cb(3s) p50=\(String(format: "%.2f", self.p50))ms \
                    p95=\(String(format: "%.2f", self.p95))ms \
                    max=\(String(format: "%.2f", sorted.last ?? 0))ms \
                    mem=\(String(format: "%.1f", Self.footprintMB()))MB
                    """)
                callbackMs.removeAll(keepingCapacity: true)
            }
        }
        guard let published = window.publish(now: now) else { return nil }
        let memory = Self.footprintMB()
        peakMB = max(peakMB, memory)
        var value = ScanDiagnostics()
        value.timestamp = now
        value.frameTimestamp = context.timestamp
        value.generation = context.generation
        value.receivedFrames = published.received
        value.processedFrames = published.processed
        value.sampledPoints = context.result.sampledPoints
        value.acceptedPoints = context.result.acceptedPoints
        value.callbackMeanMs = published.mean
        value.callbackMaxMs = published.max
        value.callbackP50Ms = p50
        value.callbackP95Ms = p95
        value.totalReceivedFrames = receivedCount
        value.totalDepthFrames = depthCount
        value.depthSource = context.depthSource
        value.continuousSeconds = window.continuousSeconds
        value.longestSeconds = window.longestSeconds
        value.gate = context.gate
        value.position = context.position
        value.originY = context.originY
        value.anchors = context.anchorCount
        value.voxelEntries = context.voxelEntries
        value.memoryMB = memory
        value.peakMemoryMB = peakMB
        return value
    }

    func reset() { window = ScanDiagnosticWindow() }

    /// 현재 프로세스 물리 메모리 사용량(MB). 실패 시 -1.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
