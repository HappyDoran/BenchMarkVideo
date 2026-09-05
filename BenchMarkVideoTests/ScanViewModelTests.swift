import XCTest
@testable import BenchMarkVideo

/// 이벤트 처리(`handle`)와 제어 메서드의 상태 전이만 검증 — test-policy 전환 조건(분기 4개) 충족으로 개방.
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
}
