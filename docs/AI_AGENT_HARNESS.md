---
title: AI Agent 작업 지원 체계
kind: design
last_verified: 2026-09-05
---

# AI Agent 작업 지원 체계

## 목적과 범위

이 문서는 이 저장소에 구현된 AI Agent 친화 문서 구조와 검증 체계를 설명한다. Agent가 과거 대화 없이 작업을 시작해 필요한 사실을 찾고, 실제 코드를 확인하고, 변경을 검증하고, 다음 세션에 근거를 남기는 운영 방식을 연결한다. Claude Code와 Codex 둘 다 같은 본문을 읽는다.

이 체계는 긴 프롬프트 하나가 아니라 다음 피드백 루프다.

```
저장소 진입 (AGENTS.md / CLAUDE.md)
  → 작업 범위와 완료 조건 확인
  → 사실의 소유 문서 선택 (문서 맵)
  → 실제 코드·빌드 설정으로 현재 상태 확인
  → 작업 유형에 맞는 skill 적용
  → 코드·소유 문서 변경
  → 단위 테스트 + 컴파일 + scripts/check-structure.sh + 실기기 수동 확인
  → LLM 제안 기각·수정 사례를 LLM_REPORT.md에 즉시 기록
  → 커밋 본문에 결정 이유와 검증 증거 보존
  → 다음 세션이 갱신된 현재 사실에서 다시 시작
```

대상 독자: 과거 대화 없이 시작하는 Agent, 프로젝트를 검토하는 사람, 좌표계·동시성 규약을 건드리는 작업자.

## 도입 배경

단일 타깃 SwiftUI 앱이지만 다음 문제가 실제로 발생했다.

- LLM이 자신 있게 틀리는 영역(좌표 변환, column-major, intrinsics 기준 해상도, `ARView.session` 소유권, 암묵 import)이 있고, 규약을 문서로 고정하지 않으면 세션마다 같은 실수를 반복한다 (`LLM_REPORT.md` 사례 1~3).
- 실기기가 없으면 런타임을 검증할 수 없다. "검증했다"와 "컴파일됐다"를 구분해 보고하지 않으면 미검증 코드가 통과로 기록된다.
- 규약·실행 명령·설계 근거·LLM 리포트가 `CLAUDE.md` 한 파일에 섞이면 일부만 갱신되어 충돌한다.
- 기능 단위 폴더링에서는 View가 Model 객체를 직접 호출하는 위반이 리뷰에서 걸리지 않았다 (`LLM_REPORT.md` 사례 4).

이를 해결하기 위한 원칙:

1. 진입점은 짧은 라우터로 유지한다.
2. 사실 하나에 소유 문서 하나.
3. 규약(TECH_RULES)과 근거(DESIGN)와 절차(skill)를 분리한다.
4. 기계적으로 판정 가능한 규칙은 스크립트로 옮긴다.
5. 구현되지 않은 문서는 만들지 않고 도입 조건만 둔다.
6. 구조적 결정의 과거 이유는 커밋 본문이, LLM 기각·수정 이력은 `LLM_REPORT.md`가 소유한다.

단일 타깃·단독 작업·원격 PR 없음이라 CI와 PR 템플릿은 아직 두지 않는다. 도입 조건은 아래 확장 조건 표에 있다.

## 권위와 사실 판정 순서

1. 실행 가능한 계약 — 소스 코드, `project.pbxproj` 빌드 설정, `scripts/check-structure.sh`.
2. `TECH_RULES.md`.
3. `AGENTS.md` 문서 맵의 소유 문서.
4. `AGENTS.md`의 작업 흐름과 절대 금지.

문서가 구현과 다르면 구현이 현재 상태다. 계약을 의도적으로 바꾸는 작업은 코드와 소유 문서를 같은 커밋에서 갱신한다. 문서별 소유 사실과 갱신 트리거는 `AGENTS.md` 문서 맵이, 파일 위치는 `docs/architecture/folder-structure.md`가 소유한다 — 여기 복사하지 않는다.

## Canonical과 도구별 진입

```
Codex   → AGENTS.md → .codex/skills/<skill>/SKILL.md
Claude  → CLAUDE.md (symlink) → AGENTS.md → .claude/skills/<skill>/SKILL.md (symlink) → .codex/skills/<skill>/SKILL.md
```

복사본은 두지 않는다. `scripts/check-structure.sh`가 두 symlink가 정확한 대상을 가리키는지 검사한다.

## Skill별 역할

| Skill | 적용 대상 | 판단 내용 |
| --- | --- | --- |
| `mvvm-architecture` | 파일 추가·이동, 새 화면, 새 파이프라인 단계 | 계층, 허용 import·참조, 이름, 확장 조건 |
| `test-policy` | 모든 코드 변경 | 단위 테스트 필수 대상, 컴파일·구조 검사·실기기 매트릭스 선택 |
| `git-commit` | 커밋 | 제목 태그, 본문 항목, 트레일러 금지 |

## 작업 흐름

1. **범위 분리.** 동작 변경 / 구조 변경 / 파라미터 튜닝 / 문서 변경 중 무엇인지, 실기기 확인이 필요한지.
2. **문서 선택.** `AGENTS.md` 작업 유형별 필독 표에 따라 소유 문서만 읽는다.
3. **구현 근거 조사.** 문서보다 코드 우선. 상수 값은 `Model/` 파일의 `static let`이 정본.
4. **계층 결정.** `mvvm-architecture`로 위치를 정하고, `test-policy`로 검증 계층을 정한다.
5. **코드·문서 동시 변경.** 파라미터가 바뀌면 `DESIGN.md`, 파일이 옮겨지면 `folder-structure.md`, LLM 제안을 고쳤으면 `LLM_REPORT.md`.
6. **검증.** `xcodebuild test`, 컴파일, `scripts/check-structure.sh`, 런타임 변경 시 실기기 매트릭스.
7. **커밋.** `git-commit` 규칙. 검증 결과와 미검증 항목을 본문에.

## 자동 검증 체계

`scripts/check-structure.sh`가 검사하는 것:

| 범주 | 검사 |
| --- | --- |
| 문서 | 필수 문서 존재, 에이전트용 문서 frontmatter(`title`, `kind`, `last_verified`; 산출 문서 `README.md`·`LLM_REPORT.md` 제외), 문서 안 인라인 코드 경로(`*.swift`, `*.md`, `*.sh`)의 실제 존재 |
| 진입점 | `CLAUDE.md → AGENTS.md` symlink, `.claude/skills/<n>/SKILL.md → .codex/skills/<n>/SKILL.md` symlink, skill frontmatter `name` 일치, 고아 symlink 없음 |
| 배치 | 모든 앱 `.swift`가 `App/ Model/ ViewModel/ View/` 아래. 테스트는 `BenchMarkVideoTests/<Type>Tests.swift`, Model 세 타입의 테스트 파일 존재, View·ViewModel 미참조 |
| 계층 규칙 | `Model/`: `SwiftUI`·`UIKit`·`Observation` import 금지, ViewModel·View 타입 참조 금지, 최상위 타입 `nonisolated` 명시. `ViewModel/`: `SwiftUI`·`UIKit`·`RealityKit` import 금지, View 타입 참조 금지. `View/`: Model 객체 타입 참조 금지, `DispatchQueue` 사용 금지 |

검사는 grep 기반이다. 간접 참조, 의미적 위반, 큐 밖에서의 상태 접근은 잡지 못한다 — 그것은 `TECH_RULES.md` 금지 표와 리뷰가 담당한다.

## 현재 한계

- CI가 없다. 검사는 로컬에서 수동 실행하며 커밋 전 실행은 `git-commit` skill의 절차에 의존한다.
- 단위 테스트는 Model 계층만 대상이다. ViewModel 상태 전이와 세션 lifecycle은 실기기 수동에 의존한다.
- 실기기 검증 결과는 커밋 본문과 `README.md` 매트릭스 형식에 의존한다. 별도 로그 문서는 없다.
- `last_verified`는 사람이 적는 날짜이며 만료 검사는 없다.
- 문서 경로 검사는 인라인 코드의 확장자 있는 경로만 본다. 폴더 표기와 fenced code block 안은 검사하지 않는다.

## 확장 조건

| 후보 | 도입 조건 | 기대 효과 |
| --- | --- | --- |
| ViewModel 테스트 | `ScanViewModel.handle` 분기가 셋을 넘을 때 | 상태 전이 회귀 고정 |
| pre-commit hook | 구조 검사를 빼먹은 커밋이 두 번 이상 | 검사 강제 |
| CI (`xcodebuild test` + 컴파일 + 구조 검사) | 원격 저장소에서 PR 리뷰 시작 | merge 전 기계 검사 |
| PR 템플릿 | 위와 동일 | 수동 매트릭스·문서 동기화 체크 |
| Feature 상위 폴더 | 화면 셋 이상 + 공유 상태 | 계층 폴더 비대화 방지 |
| ADR | 같은 결정이 두 번 이상 번복 | 대안·rollback 조건 보존 |
| 실기기 튜닝 로그 | 파라미터 조정 세 번 이상 | 튜닝 이력 추적 |

후보 도입 시 먼저 기존 소유 문서에 넣을 수 있는지 판단하고, 새 문서가 필요하면 `AGENTS.md` 문서 맵에 등록한다.
