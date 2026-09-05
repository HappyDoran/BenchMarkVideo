---
name: test-policy
description: 코드를 변경하는 모든 작업에서 적용하는 검증 규칙. 단위 테스트·컴파일·구조 검사·실기기 수동 매트릭스 중 무엇을 통과해야 완료인지 판정하고, 어떤 코드에 테스트가 필수인지 정한다.
---

# 검증 정책

코드 변경과 검증은 같은 작업·같은 커밋에서 움직인다. 검증은 실패가 의미하는 범위로 나눈다. 실행 명령은 `README.md`가 소유한다.

## 검증 계층

| 계층 | 잡는 것 | 명령 | 언제 |
| --- | --- | --- | --- |
| 단위 테스트 | 좌표 변환, 격자 분기, crop 계산 같은 Model 순수 로직의 회귀 | `xcodebuild test … -destination 'platform=iOS Simulator,…'` | Model 변경 |
| 컴파일 | 타입·격리·import 오류 | `xcodebuild … build CODE_SIGNING_ALLOWED=NO` | 모든 코드 변경 |
| 구조 검사 | MVVM 배치, 계층 import 규칙, `nonisolated` 누락, 테스트 배치, 문서 symlink·경로·frontmatter | `scripts/check-structure.sh` | 모든 변경 |
| 실기기 수동 | 실제 스케일·필터 파라미터, 권한·세션 lifecycle, 성능 | `README.md` 수동 매트릭스, `DESIGN.md` 10절 | 런타임 동작·파라미터 변경 |

## 테스트 위치와 범위

- 타깃 `BenchMarkVideoTests` (호스트 앱 필요, 시뮬레이터 실행). 파일은 `BenchMarkVideoTests/<Type>Tests.swift`.
- 대상은 `Model/`만. `sceneDepth` 없이 실행 가능한 순수 함수와 큐 전용 객체의 동기 메서드를 직접 호출한다. `CVPixelBuffer`는 테스트에서 직접 만든다.
- View는 테스트하지 않는다. ViewModel은 `ScanViewModel.handle` 분기가 넷이 된 시점(`meshReady` 추가)에 전환 조건이 충족돼 `internal`로 열었다 — 이벤트 처리와 제어 메서드의 상태 전이만 `ScanViewModelTests.swift`에서 검증하고, 세션 부작용(ARSession)은 여전히 실기기 대상이다.
- `ARSessionManager`는 delegate 콜백이 `ARFrame`을 요구해 단위 테스트 대상이 아니다. 실기기 매트릭스로 본다.

## 판정 기준: 테스트가 필수인 코드

한 문장 규칙 — **"이 코드가 깨지면 조용히 틀린 지도가 나가는가?"** 그렇다면 테스트 필수.

| 대상 | 테스트 | 현재 파일 |
| --- | --- | --- |
| 좌표 변환 (intrinsics 스케일, flipYZ, column-major translation, heading) | **필수** | `DepthFrameProcessorTests.swift` |
| 버퍼 경계 (stride 샘플링, confidence·depth 범위 필터) | **필수** — 걸러져야 할 입력이 걸러지는 케이스 포함 | `DepthFrameProcessorTests.swift` |
| 격자 인덱싱과 범위 밖 처리 | **필수** | `OccupancyGridTests.swift` |
| 높이 밴드 분기 (벽/바닥/천장), bounds, reset | **필수** | `OccupancyGridTests.swift` |
| crop 크기와 정규화 좌표 | 필수 | `MinimapRendererTests.swift` |
| 상태 머신 전이 (`ScanState`, 이벤트 → 배지 상태) | **필수** (분기 4개로 전환 조건 충족) | `ScanViewModelTests.swift` |
| 녹화 진단 창 집계·연속 시간 reset | **필수** — 계측 수치 자체의 오판 방지 | `ScanDiagnosticsTests.swift` |
| 세션 lifecycle, 트래킹 경고, 권한 | 실기기 수동 | — |
| 레이아웃·버튼 배선, 상수, 단순 위임 | 제외 | — |

`scripts/check-structure.sh`는 세 Model 타입의 테스트 파일이 존재하는지, 테스트가 View를 참조하지 않는지(ViewModel은 `ScanViewModelTests.swift`에서만) 검사한다.

## 새 기능·수정 시

1. 위 표의 "필수" 대상을 만들거나 고치면 같은 커밋에서 테스트를 추가·갱신한다. 케이스는 정상 경로 1개 + 경계값 + 걸러져야 할 입력. 모든 조합이 아니라 깨지면 아픈 지점만.
2. 수정 전 `xcodebuild test`가 녹색인지 확인한다. 의도치 않게 빨간불이 나면 기대값이 아니라 코드를 의심한다 — 특히 좌표 규약(`TECH_RULES.md` 2절) 위반.
3. 파라미터 값을 바꾸면 테스트가 상수를 참조하는지 확인하고(리터럴 금지), `DESIGN.md` 해당 절의 값·되돌리기 조건을 갱신한다.
4. 실기기 결과가 기대와 다르면 재현 값을 테스트 케이스로 먼저 고정한 뒤 고친다. 사례는 `LLM_REPORT.md`.

## 완료 조건

- `xcodebuild test`, 컴파일, `scripts/check-structure.sh` 통과.
- 런타임 동작이 바뀌었으면 `기기 × 시나리오 × 결과` 표를 커밋 본문 또는 완료 보고에 남긴다. 실기기가 없으면 "미검증"으로 적는다.
- 완료 보고에 추가·수정한 테스트 파일과 케이스 수를 포함한다.
