@preconcurrency import ARKit
import Foundation
import simd

/// Model → ViewModel 단일 출력. 한 스트림으로 흐르므로 순서가 보존된다
/// (초기화 직후 빈 스냅샷이 옛 스냅샷 뒤에, 이벤트가 그 프레임의 스냅샷 앞에).
nonisolated enum ScanOutput: Sendable {
    case snapshot(MinimapSnapshot)
    case event(ScanEvent)
    /// 1.5초 주기, 입력(앵커 수·누적 점 수) 변경 시에만.
    case mesh(ColoredMesh)
    case pointCloud(GridPointCloud)
    /// .ply 임시 파일. 쓰기 실패 시 nil — 이전 스캔의 stale 파일이 공유되지 않게.
    case plyFile(URL?)
    #if SCAN_DIAGNOSTICS
    case diagnostics(ScanDiagnostics)
    #endif
}

/// 프레임 한 장에서 파이프라인이 읽는 값. `ARFrame` 자체는 넘기지 않는다 (프레임 풀 고갈 방지).
/// 버퍼는 `process` 호출 동안만 유효 — 파이프라인은 동기로 소비하고 보관하지 않는다.
nonisolated struct FrameInput {
    var timestamp: TimeInterval
    var cameraTransform: simd_float4x4
    var intrinsics: simd_float3x3 = matrix_identity_float3x3
    var imageResolution: CGSize = .zero
    var depthMap: CVPixelBuffer?
    var confidenceMap: CVPixelBuffer?
    var capturedImage: CVPixelBuffer?
    /// smoothed / raw — 진단 표시용. depthMap이 nil이면 무시.
    var depthSource: String = "smoothed"
    var meshAnchors: [ARMeshAnchor] = []
}

/// 세션 매니저가 판정한 게이트. 파이프라인은 판정하지 않고 따르기만 한다.
nonisolated struct FrameGate {
    /// 스캔을 한 번이라도 시작했는가 — 높이 기준 고정·mesh 빌드·궤적 대상.
    var started: Bool
    /// 이번 프레임을 격자에 누적하는가 (누적 중 ∧ tracking normal ∧ 안정화 창 밖).
    var accumulate: Bool
    /// 궤적을 기록하는가 (시작됨 ∧ tracking normal ∧ 안정화 창 밖). 일시정지 중에도 참.
    var track: Bool
}

/// `process` 한 번의 결과 — 진단 표시용.
nonisolated struct FrameResult {
    var sampledPoints = 0
    var acceptedPoints = 0
    /// 누적이 허용됐는데 깊이가 없어 건너뛴 프레임.
    var missingDepth = false
}

/// 깊이 프레임 → 격자·복셀 색·궤적 → 스냅샷/mesh/내보내기. `scan.processing` 큐 전용 가변 상태.
/// 세션·트래킹·게이트 판정은 `ARSessionManager`가 갖고, 여기는 누적과 출력만 한다.
/// @unchecked Sendable: 모든 가변 상태는 `queue`에서만 접근한다는 규약으로 보장.
nonisolated final class ScanPipeline: @unchecked Sendable {

    /// 궤적 기록 최소 이동 거리(m). 시작값 — 상한 도달 시 데시메이션과 함께 배가.
    static let trajectoryStep: Float = 0.25
    /// 궤적 점 수 상한 — 격자처럼 메모리·스냅샷 복사 비용을 고정 (2048점 × 8B = 16KB).
    /// 도달하면 점을 절반 솎고 기록 간격을 배가 — 경로 형태는 유지, 해상도만 낮아진다.
    static let trajectoryMaxPoints = 2048
    /// 시작 후 첫 mesh 빌드까지 지연(s) — 시작 순간의 와이어프레임 첫 렌더와 수만 정점
    /// 빌드·업로드가 겹쳐 GPU가 붐비지 않게 한 박자 미룬다.
    static let meshFirstDelay: TimeInterval = 0.6
    /// mesh 재빌드 주기(s) — 미니맵 배경·3D 뷰어 공용.
    static let meshInterval: TimeInterval = 1.5

    private let queue: DispatchQueue
    private let emit: @Sendable (ScanOutput) -> Void
    private let grid = OccupancyGrid()
    /// 3D 뷰어 정점 색용 월드 복셀 색.
    private let voxelColors = VoxelColorStore()

    /// 스캔 시작 시 카메라 월드 y — 높이 밴드 기준. 월드 원점은 앱 실행 시점에 고정되므로
    /// (책상에 둔 채 실행 후 들고 스캔 등) 실행 높이와 스캔 높이의 차를 여기로 보정한다.
    private(set) var scanOriginY: Float?
    private(set) var trajectory: [SIMD2<Float>] = []
    /// 현재 궤적 기록 간격(m) — 데시메이션마다 배가, reset에서 초기값 복원.
    private(set) var trajectoryStride: Float = ScanPipeline.trajectoryStep
    /// 직전 스냅샷 — 격자 미변경 시 렌더러가 이미지를 재사용.
    private var lastSnapshot: MinimapSnapshot?
    /// 마지막 유효 yaw — 카메라가 수직(바닥/천장)을 볼 때 노이즈 회전 방지용.
    private var lastHeading: Float = 0
    /// 마지막 mesh 빌드의 입력 서명(앵커 수 + 누적 점 수) — 미변경 시 재빌드 생략 (발열·큐 경합 방지).
    private var lastMeshInputSignature = -1
    private var meshBuildCount = 0
    /// 다음 mesh 빌드 허용 시각. nil = 시작 전. `markStarted` 후 첫 프레임에서 `meshFirstDelay`로 잡는다.
    private var nextMeshTime: TimeInterval?
    private var pendingFirstMesh = false
    /// 초기화 세대 — reset마다 증가. 초기화 전 세대의 mesh가 늦게 도착하는 것을 구분한다.
    private(set) var generation = 0

    var totalPoints: Int { grid.totalPoints }
    #if SCAN_DIAGNOSTICS
    var voxelEntryCount: Int { voxelColors.diagnosticEntryCount }
    #endif

    init(queue: DispatchQueue, emit: @escaping @Sendable (ScanOutput) -> Void) {
        self.queue = queue
        self.emit = emit
    }

    /// 스캔 시작·재개 — 다음 프레임에서 첫 mesh 빌드 시각을 잡는다 (큐에서 호출).
    func markStarted() {
        if nextMeshTime == nil { pendingFirstMesh = true }
    }

    /// 프레임 하나 처리 (큐에서 동기 호출). 스냅샷은 매번 발행 — 일시정지 중에도 위치 마커는 움직인다.
    @discardableResult
    func process(_ input: FrameInput, gate: FrameGate) -> FrameResult {
        var result = FrameResult()
        let transform = input.cameraTransform
        let position = SIMD2(transform.columns.3.x, transform.columns.3.z)
        // 스캔 첫 프레임의 카메라 높이를 밴드 기준으로 고정 (reset에서 해제)
        if gate.started, scanOriginY == nil { scanOriginY = transform.columns.3.y }
        // 시선이 수직에 가까우면 yaw가 노이즈라 마지막 유효값 유지
        let look = -transform.columns.2
        if look.x * look.x + look.z * look.z > 0.01 {
            lastHeading = DepthFrameProcessor.heading(of: transform)
        }

        if gate.accumulate {
            if let depthMap = input.depthMap {
                let points = DepthFrameProcessor.worldPoints(
                    depthMap: depthMap,
                    confidenceMap: input.confidenceMap,
                    capturedImage: input.capturedImage,
                    intrinsics: input.intrinsics,
                    imageResolution: input.imageResolution,
                    cameraTransform: transform)
                let before = grid.totalPoints
                grid.accumulate(points: points, originY: scanOriginY ?? 0)
                voxelColors.accumulate(points: points)   // 3D 뷰어 정점 색
                result.sampledPoints = points.count
                result.acceptedPoints = grid.totalPoints - before
            } else {
                result.missingDepth = true
            }
        }

        // 궤적은 일시정지 중에도 기록 — 어디로 걸어갔는지는 누적 여부와 무관하게 보여야 한다.
        if gate.track, trajectory.last.map({ simd_distance($0, position) >= trajectoryStride }) ?? true {
            trajectory.append(position)
            // 상한 도달 시 절반 솎고 간격 배가 — 격자처럼 메모리·복사 비용을 고정.
            // 마지막 점(현재 위치)은 짝수 stride에서 탈락할 수 있어 명시 보존.
            if trajectory.count >= Self.trajectoryMaxPoints {
                var decimated = Swift.stride(from: 0, to: trajectory.count, by: 2).map { trajectory[$0] }
                if (trajectory.count - 1) % 2 != 0, let last = trajectory.last { decimated.append(last) }
                trajectory = decimated
                trajectoryStride *= 2
            }
        }

        // 격자 미변경 시 이미지는 재사용(lastSnapshot).
        let snapshot = MinimapRenderer.render(grid: grid, cameraPosition: position,
                                              cameraHeading: lastHeading, trajectory: trajectory,
                                              previous: lastSnapshot)
        lastSnapshot = snapshot
        emit(.snapshot(snapshot))

        scheduleMeshIfDue(at: input.timestamp, anchors: input.meshAnchors, started: gate.started)
        return result
    }

    /// mesh 빌드는 콜백 밖(같은 큐의 다음 블록)에서 — 콜백 예산을 지키면서 격자 접근은 직렬 유지.
    private func scheduleMeshIfDue(at timestamp: TimeInterval, anchors: [ARMeshAnchor], started: Bool) {
        guard started else { return }
        if pendingFirstMesh {
            pendingFirstMesh = false
            nextMeshTime = timestamp + Self.meshFirstDelay
        }
        guard let due = nextMeshTime, timestamp >= due else { return }
        nextMeshTime = timestamp + Self.meshInterval
        let signature = anchors.count &* 1_000_003 &+ grid.totalPoints
        guard signature != lastMeshInputSignature else { return }
        lastMeshInputSignature = signature
        let generation = self.generation
        queue.async { [self] in
            guard generation == self.generation else { return }   // 사이에 초기화됐으면 옛 앵커 폐기
            meshBuildCount += 1
            #if SCAN_DIAGNOSTICS
            let buildStart = ProcessInfo.processInfo.systemUptime
            #endif
            var mesh = MeshBuilder.coloredMesh(anchors: anchors, colors: voxelColors)
            mesh.version = meshBuildCount
            #if SCAN_DIAGNOSTICS
            mesh.diagnosticGeneration = generation
            mesh.diagnosticSourceTimestamp = timestamp
            mesh.diagnosticBuildMs = (ProcessInfo.processInfo.systemUptime - buildStart) * 1000
            #endif
            emit(.mesh(mesh))
        }
    }

    /// 격자·복셀·궤적 전부 초기화하고 빈 스냅샷을 발행 — 큐에 남아 있던 프레임의 옛 격자 잔상을 즉시 덮는다.
    func reset() {
        generation += 1
        scanOriginY = nil
        grid.reset()
        voxelColors.reset()
        trajectory = []
        trajectoryStride = Self.trajectoryStep
        lastHeading = 0
        lastSnapshot = nil
        lastMeshInputSignature = -1
        nextMeshTime = nil
        pendingFirstMesh = false
        emit(.snapshot(MinimapRenderer.render(grid: grid, cameraPosition: .zero,
                                              cameraHeading: 0, trajectory: [])))
    }

    /// 현재 격자를 .ply 임시 파일로 써서 `.plyFile` 발행 (선택 요구사항: 내보내기).
    func exportPly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan.ply")
        let written = (try? GridExporter.ply(grid: grid).write(to: url, atomically: true, encoding: .utf8)) != nil
        emit(.plyFile(written ? url : nil))
    }

    /// 현재 격자를 점군 값으로 발행 — 3D 뷰어의 mesh 없을 때 fallback.
    func exportPointCloud() {
        emit(.pointCloud(GridExporter.pointCloud(grid: grid)))
    }
}
