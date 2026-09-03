# LLM 활용 리포트

> 작성 규칙: 사례 발생 즉시 추가 (몰아 쓰기 금지). 제출 전 최종 정리.

## 1. 사용한 도구와 워크플로우

- **도구**: Claude Code (CLI)
- **워크플로우**: 과제 명세 전체를 컨텍스트로 제공 → 브리핑/아키텍처 합의 → 프로젝트 `CLAUDE.md`에 좌표계·동시성 규약을 먼저 고정 → 모듈 단위로 구현 위임 → 매 단계 `xcodebuild` 컴파일 검증 → 실기기 테스트 결과를 피드백으로 재투입.
- **에이전트 컨텍스트 세팅** (`CLAUDE.md`): LLM이 자신 있게 틀리는 영역(좌표 변환, column-major, intrinsics 방향)을 규약으로 박아 두고, 동시성 규칙(scan.processing 큐 전용 접근)과 커밋 표기 규칙(`[llm]`/`[human]`/`[llm+human]`)을 명시. 의도: 세션이 바뀌어도 같은 규약으로 작업 이어가기 + 리포트 작성 근거를 커밋 로그에 남기기.

## 2. 역할 구분

| 파일/모듈 | 작성 주체 | 비고 |
|---|---|---|
| `Scan/DepthFrameProcessor.swift` | LLM 초안 | unprojection 수식은 Apple 샘플의 flipYZ 방식 채택. 실기기 검증 예정 (벽 길이 비교) |
| `Scan/ARSessionManager.swift` | LLM 초안 | 스로틀 주기·pause 의미(세션 유지, 누적만 중단)는 사람이 결정 |
| `Minimap/OccupancyGrid.swift` | LLM 초안 | 격자 해상도(5cm)·높이 밴드 파라미터는 실기기 튜닝 예정 |
| `Minimap/MinimapRenderer.swift` | LLM 초안 | auto-fit crop 방식 |
| `Minimap/MinimapView.swift`, `UI/*`, `ContentView.swift` | LLM 생성 | UI 보일러플레이트 |
| `ScanViewModel.swift` | LLM 생성 | |
| 아키텍처 결정 (RealityKit mesh 시각화로 Metal 렌더러 대체, north-up 고정, 고정 격자 채택) | 사람 (LLM 브리핑 기반 합의) | 근거는 DESIGN.md |

## 3. LLM이 틀렸던 지점 / 수정 사례

### 사례 1 — ARView.session 소유권 설계 오류 (설계 수정)
- **무엇**: LLM 초안의 `ARSessionManager`가 `ARSession`을 직접 생성·소유하고 ARView에 주입하는 구조로 작성.
- **어떻게 알았나**: RealityKit `ARView.session`은 **get-only** — 외부 세션 주입 불가.
- **수정**: 소유권 반전 — ARView가 세션을 소유하고 매니저는 `attach(to:)`로 delegate만 연결.

### 사례 2 — CVPixelBuffer 포인터 타입 불일치 (컴파일 오류)
- **무엇**: confidence map 접근에서 `UnsafePointer<UInt8>?` 변수에 `CVPixelBufferGetBaseAddress` 결과(`UnsafeMutableRawPointer` → `assumingMemoryBound`는 Mutable 포인터 반환)를 대입.
- **어떻게 알았나**: `xcodebuild` 검증에서 "type of expression is ambiguous" — 에러 위치가 대입문이라 타입 추적으로 파악.
- **수정**: `UnsafeMutablePointer<UInt8>?`로 선언 변경. 매 모듈 컴파일 검증을 파이프라인에 둔 이유.

### 사례 3 — MemberImportVisibility로 인한 암묵 import 실패
- **무엇**: `MinimapRenderer`에서 `Data` 사용하며 `Foundation` import 누락 (LLM이 CoreGraphics 경유 암묵 import 가정). Xcode 26 신규 프로젝트는 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`라 실패.
- **수정**: 명시 import 추가.

<!-- 실기기 검증 단계에서 좌표 변환·필터 파라미터 관련 사례 추가 예정 -->

## 4. 핵심 프롬프트 발췌

(제출 전 정리 — 후보: ① 과제 명세 전체 + 브리핑 요청 → 아키텍처 합의, ② CLAUDE.md 규약 선행 작성 지시, ③ 실기기 테스트 피드백 루프 프롬프트)
