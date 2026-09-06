import simd
import XCTest
@testable import BenchMarkVideo

/// 출력 반영(`apply`·`handle`)과 제어 메서드·전체화면 상태 전이만 검증 — test-policy 전환 조건(분기 4개) 충족으로 개방.
/// ARSession은 attach하지 않으므로 세션 부작용 없이 순수 상태 전이만 돈다.
@MainActor
final class ScanViewModelTests: XCTestCase {

    func testHandleUpdatesEachEventState() {
        let vm = ScanViewModel()
        vm.handle(.trackingChanged(message: "경고"))
        XCTAssertEqual(vm.trackingMessage, "경고")
        vm.handle(.trackingChanged(message: nil))
        XCTAssertNil(vm.trackingMessage)

        vm.handle(.sessionFailed(message: "오류", isPermissionDenied: true))
        XCTAssertEqual(vm.fatalMessage, "오류")
        XCTAssertTrue(vm.isPermissionDenied)

        vm.handle(.interruptionChanged(isInterrupted: true))
        XCTAssertTrue(vm.isInterrupted)

        vm.handle(.meshReady)
        XCTAssertTrue(vm.isMeshReady)
    }

    func testRetryClearsAllBadgeState() {
        // 중단 중 세션 오류 → 다시 시도: 새 세션은 interruptionEnded를 보내지 않으므로
        // retry가 배지 상태를 직접 지워야 한다 (잔류 버그 회귀 고정).
        let vm = ScanViewModel()
        vm.handle(.interruptionChanged(isInterrupted: true))
        vm.handle(.trackingChanged(message: "경고"))
        vm.handle(.sessionFailed(message: "오류", isPermissionDenied: false))
        vm.retry()
        XCTAssertFalse(vm.isInterrupted)
        XCTAssertNil(vm.trackingMessage)
        XCTAssertNil(vm.fatalMessage)
        XCTAssertFalse(vm.isPermissionDenied)
        XCTAssertEqual(vm.state, .ready)
    }

    func testStateTransitionsAndMeshReadyResetCycle() {
        let vm = ScanViewModel()
        XCTAssertEqual(vm.state, .ready)
        vm.start()
        XCTAssertEqual(vm.state, .scanning)
        vm.pause()
        XCTAssertEqual(vm.state, .paused)
        vm.handle(.meshReady)
        vm.reset()
        XCTAssertEqual(vm.state, .ready)
        XCTAssertFalse(vm.isMeshReady)   // 초기화 후 다음 meshReady까지 배지 대상
    }

    func testApplyRoutesEachOutput() {
        let vm = ScanViewModel()
        var mesh = ColoredMesh(); mesh.positions = [.zero]; mesh.version = 3
        vm.apply(.mesh(mesh))
        XCTAssertEqual(vm.liveMesh?.version, 3)
        vm.apply(.event(.meshReady))
        XCTAssertTrue(vm.isMeshReady)
        let url = URL(fileURLWithPath: "/tmp/scan.ply")
        vm.apply(.plyFile(url))
        XCTAssertEqual(vm.exportURL, url)
        vm.apply(.plyFile(nil))
        XCTAssertNil(vm.exportURL)          // 쓰기 실패 = 공유 버튼 숨김
    }

    func testExpandedMapAutoPausesOnlyWhenScanning() {
        let vm = ScanViewModel()
        vm.start()
        vm.openExpandedMap()
        XCTAssertTrue(vm.isMapExpanded)
        XCTAssertEqual(vm.state, .paused)   // 보는 동안 데이터가 흐르지 않게
        vm.closeExpandedMap()
        XCTAssertFalse(vm.isMapExpanded)
        XCTAssertEqual(vm.state, .scanning) // 열기 전 상태로 복귀

        vm.pause()                          // 수동 일시정지는 존중
        vm.openExpandedMap()
        vm.closeExpandedMap()
        XCTAssertEqual(vm.state, .paused)
    }

    func testCloseExpandedMapResetsViewerState() {
        let vm = ScanViewModel()
        var mesh = ColoredMesh(); mesh.positions = [.zero]
        vm.apply(.mesh(mesh))
        vm.openExpandedMap()
        vm.mapViewMode = .cloud3D
        XCTAssertNotNil(vm.frozenMesh)      // 3D 진입 시점 고정
        vm.addMeasurePoint(world: SIMD2(0, 0))
        vm.addMeasurePoint(world: SIMD2(1, 0))
        vm.addMeasurePoint(world: SIMD2(2, 0))
        XCTAssertEqual(vm.measurePoints, [SIMD2(2, 0)])   // 세 번째 탭 = 새 측정
        vm.zoomWorldWindow(radius: 100)
        XCTAssertEqual(vm.viewRadius, ScanViewModel.viewRadiusRange.upperBound)
        vm.closeExpandedMap()
        XCTAssertTrue(vm.measurePoints.isEmpty)
        XCTAssertNil(vm.frozenMesh)
        XCTAssertEqual(vm.mapViewMode, .map2D)
        XCTAssertNil(vm.viewCenter)
    }

    func testMeasurePointIgnoredWithoutMesh() {
        // 격자 fallback은 세계 창과 매핑이 달라 측정을 받지 않는다
        let vm = ScanViewModel()
        vm.addMeasurePoint(world: SIMD2(1, 1))
        XCTAssertTrue(vm.measurePoints.isEmpty)
    }
}
