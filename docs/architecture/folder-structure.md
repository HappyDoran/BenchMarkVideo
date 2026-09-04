---
title: 현재 폴더 구성 스냅샷
kind: snapshot
last_verified: 2026-09-04
---

# 현재 폴더 구성 스냅샷

파일을 추가·이동·삭제하면 이 문서를 같은 커밋에서 갱신한다. 배치 규칙 자체는 `.codex/skills/mvvm-architecture/SKILL.md`가 소유하고, 규칙 위반은 `scripts/check-structure.sh`가 잡는다. 이 문서는 "지금 무엇이 어디 있는가"만 적는다.

```
.
├── AGENTS.md                         # 도구 중립 진입점, 문서 맵, 작업 흐름
├── CLAUDE.md -> AGENTS.md            # Claude용 진입 symlink
├── TECH_RULES.md                     # 스택, 좌표계·동시성 규약, 금지
├── README.md                         # 빌드·검증 명령, 실기기 수동 매트릭스
├── DESIGN.md                         # 설계 판단 근거 (MVVM, 격자, 필터, 스로틀 …)
├── LLM_REPORT.md                     # LLM 활용 리포트
├── docs/
│   ├── AI_AGENT_HARNESS.md           # Agent 작업 지원 체계 설명
│   ├── architecture/folder-structure.md
│   ├── spec/requirements.md              # 요구사항 번호·산출물·배점 요약
│   └── spec/gap-analysis.md              # 명세 대비 갭 분석·보완 백로그
├── .codex/skills/                    # canonical skill (Codex 진입)
│   ├── mvvm-architecture/SKILL.md
│   ├── test-policy/SKILL.md
│   └── git-commit/SKILL.md
├── .claude/skills/<name>/SKILL.md -> ../../../.codex/skills/<name>/SKILL.md
├── scripts/check-structure.sh        # 구조·문서 계약 검사
├── Threei_Assignment.xcodeproj/      # PBXFileSystemSynchronizedRootGroup — 디스크 = 타깃
│   └── xcshareddata/xcschemes/Threei_Assignment.xcscheme   # 공유 scheme (build + test)
├── Threei_AssignmentTests/           # XCTest 타깃, Model 계층만 대상, 시뮬레이터 실행
│   ├── DepthFrameProcessorTests.swift    # intrinsics 스케일, flipYZ, column-major, heading, 버퍼 필터
│   ├── OccupancyGridTests.swift          # cellIndex, 벽/바닥/천장 분기, bounds, reset
│   └── MinimapRendererTests.swift        # crop 크기, 정규화 좌표
└── Threei_Assignment/
    ├── App/
    │   └── Threei_AssignmentApp.swift    # @main. ContentView 진입
    ├── Model/                            # nonisolated, scan.processing 큐 전용
    │   ├── ARSessionManager.swift        # ARSession delegate, 스로틀, 궤적, ScanEvent 발행
    │   ├── DepthFrameProcessor.swift     # depth → 월드 점 unprojection, heading (순수 함수)
    │   ├── OccupancyGrid.swift           # 5cm × 400×400 hit 격자, 높이 밴드 필터
    │   └── MinimapRenderer.swift         # 격자 → CGImage crop, MinimapSnapshot 정의
    ├── ViewModel/                        # MainActor
    │   └── ScanViewModel.swift           # @Observable 상태 허브, ScanState, 세션 attach 중계
    ├── View/                             # SwiftUI, ViewModel과 불변 스냅샷만 참조
    │   ├── ContentView.swift             # 화면 조립, 상태바, 제어 버튼, 예외 화면
    │   ├── ARPreviewView.swift           # UIViewRepresentable — ARView 생성, 세션 콜백
    │   └── MinimapView.swift             # 미니맵 이미지 + 궤적·마커 Canvas
    └── Assets.xcassets/
```

## 계층별 책임

| 계층 | 실행 문맥 | 담는 것 | 담지 않는 것 |
| --- | --- | --- | --- |
| `App/` | MainActor | 앱 진입점, 루트 View 선택 | 비즈니스 로직 |
| `Model/` | `scan.processing` 큐 | ARKit 세션 제어, 깊이 파이프라인, 격자, 렌더 비트맵, 이벤트·스냅샷 값 타입 | SwiftUI·UIKit·Observation import, ViewModel 참조 |
| `ViewModel/` | MainActor | UI 상태(`ScanState`, 스냅샷, 경고 메시지), 이벤트 → 상태 변환, Model 제어 호출 | SwiftUI View 타입, 레이아웃 |
| `View/` | MainActor | SwiftUI 레이아웃, 사용자 입력 → ViewModel 메서드 | Model 객체 직접 호출, 큐 접근 |

## 현재 예외

- `MinimapSnapshot`과 `ScanEvent`는 `Model/`에 정의된 값 타입이지만 `View/`·`ViewModel/`이 직접 읽는다. 불변 `Sendable`이므로 허용 (`TECH_RULES.md` 금지 표의 예외 항목).
- `ARPreviewView`는 `ARSession` 타입을 콜백 시그니처에 쓰기 위해 `ARKit`을 import한다. Model 객체를 참조하지는 않는다.
- 테스트는 Model 계층만 대상이다. ViewModel·View 테스트는 없고, 도입 조건은 `.codex/skills/test-policy/SKILL.md`.
