#if SCAN_DIAGNOSTICS
import Foundation
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
#endif
