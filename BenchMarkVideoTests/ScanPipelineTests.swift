import simd
import XCTest
@testable import BenchMarkVideo

/// 깊이 없이 돌릴 수 있는 파이프라인 규칙만 — 궤적 stride·게이트, 시작 높이 고정, reset 세대, mesh 스케줄.
/// 역투영·격자 누적은 각자의 테스트가 본다.
final class ScanPipelineTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScanOutput] = []
        func append(_ o: ScanOutput) { lock.lock(); items.append(o); lock.unlock() }
        var all: [ScanOutput] { lock.lock(); defer { lock.unlock() }; return items }
        var snapshots: [MinimapSnapshot] { all.compactMap { if case .snapshot(let s) = $0 { s } else { nil } } }
        var meshCount: Int { all.filter { if case .mesh = $0 { true } else { false } }.count }
    }

    private let queue = DispatchQueue(label: "test.scan")
    private var sink = Sink()
    private var pipeline: ScanPipeline!

    override func setUp() {
        sink = Sink()
        let sink = sink
        pipeline = ScanPipeline(queue: queue) { sink.append($0) }
    }

    private func frame(t: TimeInterval, x: Float = 0, y: Float = 1.4, z: Float = 0) -> FrameInput {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return FrameInput(timestamp: t, cameraTransform: m)
    }

    private func run(_ input: FrameInput, started: Bool = true, accumulate: Bool = false, track: Bool = true) {
        let gate = FrameGate(started: started, accumulate: accumulate, track: track)
        queue.sync { pipeline.process(input, gate: gate) }
    }

    func testTrajectoryFollowsGateAndStride() {
        run(frame(t: 0, x: 0))
        run(frame(t: 0.1, x: 0.1))                       // stride(0.25) 미만 — 미기록
        run(frame(t: 0.2, x: 0.3))                       // 기록
        run(frame(t: 0.3, x: 1.0), track: false)         // tracking limited·안정화 창 — 미기록
        XCTAssertEqual(pipeline.trajectory, [SIMD2(0, 0), SIMD2(0.3, 0)])
        XCTAssertEqual(sink.snapshots.count, 4)          // 스냅샷은 게이트와 무관하게 매 프레임
        XCTAssertEqual(sink.snapshots.last?.cameraPosition, SIMD2(1.0, 0))
    }

    func testOriginYFixedAtFirstStartedFrame() {
        run(frame(t: 0, y: 1.0), started: false, track: false)
        XCTAssertNil(pipeline.scanOriginY)               // 시작 전 이동은 기준이 아니다
        run(frame(t: 0.1, y: 1.4))
        run(frame(t: 0.2, y: 2.0))
        XCTAssertEqual(pipeline.scanOriginY, 1.4)
    }

    func testResetClearsStateBumpsGenerationAndEmitsEmptySnapshot() {
        run(frame(t: 0))
        run(frame(t: 0.1, x: 0.5))
        queue.sync { pipeline.reset() }
        XCTAssertEqual(pipeline.generation, 1)
        XCTAssertTrue(pipeline.trajectory.isEmpty)
        XCTAssertNil(pipeline.scanOriginY)
        XCTAssertEqual(pipeline.trajectoryStride, ScanPipeline.trajectoryStep)
        let last = sink.snapshots.last
        XCTAssertEqual(last?.totalPoints, 0)
        XCTAssertEqual(last?.cameraPosition, .zero)
    }

    func testMeshBuildsAfterFirstDelayThenSkipsUnchangedInput() {
        queue.sync { pipeline.markStarted() }
        run(frame(t: 10))                                          // 첫 프레임: 빌드 시각 = 10 + 0.6
        run(frame(t: 10.5))
        queue.sync {}
        XCTAssertEqual(sink.meshCount, 0)
        run(frame(t: 10.7))                                        // 지연 경과 → 빌드
        queue.sync {}
        XCTAssertEqual(sink.meshCount, 1)
        run(frame(t: 12.5))                                        // 주기 경과, 입력(앵커 0·점 0) 불변 → 생략
        queue.sync {}
        XCTAssertEqual(sink.meshCount, 1)
    }

    func testMeshBuildDoesNotRunBeforeStart() {
        run(frame(t: 0), started: false, track: false)
        run(frame(t: 5), started: false, track: false)
        queue.sync {}
        XCTAssertEqual(sink.meshCount, 0)
    }
}
