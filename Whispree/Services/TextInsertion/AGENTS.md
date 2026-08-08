<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-08-08 -->

# TextInsertion

## Purpose
FIFO delivery head job의 전사/교정 결과를 이전 앱에 붙여넣기. 클립보드 + CGEvent Cmd+V 시뮬레이션.

## Key Files

| File | Description |
|------|-------------|
| `TextInsertionService.swift` | 비동기 텍스트 삽입 — 이전 앱 활성화 → 클립보드 복사 → CGEvent Cmd+V. 유효한 대상 앱 없으면 클립보드 전용 폴백 |

## For AI Agents

### Working In This Directory
- **Accessibility 권한 필수** (`AXIsProcessTrusted`) — 없으면 CGEvent 전송 실패
- `Task.sleep` 사용 (Thread.sleep 아님) — MainActor yield
- job `targetContext`/target app이 nil이면 (예: Settings 창에서 녹음 시) 클립보드 전용 폴백
- CGEvent 시뮬레이션은 일부 앱에서 동작하지 않을 수 있음 (보안 설정)
- Text/image insertion은 `RecordingCoordinator`의 FIFO delivery 단계에서만 호출되어야 한다. 녹음 중 delivery를 시작하지 말고, 여러 ready job을 병렬로 삽입하지 말 것.
- `insertImages()`가 이미지마다 **Ctrl+V와 Cmd+V를 둘 다** 전송하는 것은 의도된 설계다. Codex CLI와 Claude CLI가 붙여넣기 키를 다르게 처리하므로 양쪽 모두 동작시키기 위함이다. `ExternalContext`에 `.iTerm2Session` / `.chromeTab` 구분이 있어 target별로 분기하고 싶어질 수 있지만 **분기하지 말 것** — 두 CLI가 같은 터미널 안에서 동시에 쓰일 수 있다. 정적 분석이 "중복 전송"으로 오인하기 쉬운 지점이니 "정리"하지 말 것.
- `insertImages()`는 루프 내 매 iteration마다 `Task.isCancelled`를 확인해야 하고, `switchToASCIIInputSource()` 호출 이후의 입력 소스 복원은 반드시 `defer`로 보장해야 한다. 이 전환은 **systemwide** 입력 소스를 바꾸므로, 복원을 건너뛰는 조기 종료 경로가 하나라도 있으면 모든 앱에서 한글 입력이 막힌다.

<!-- MANUAL: -->
