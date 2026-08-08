<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-08-08 -->

# Coordinators

## Purpose
병렬 dictation queue 오케스트레이션. 녹음은 job으로 enqueue하고, STT/LLM은 provider별 concurrency 정책에 따라 병렬 처리하며, 스크린샷 선택 + 텍스트/이미지 삽입은 녹음 중 block되는 FIFO delivery로 직렬 조율.

## Key Files

| File | Description |
|------|-------------|
| `RecordingCoordinator.swift` | `@MainActor` — active recording, `DictationQueueState`, provider-bounded STT/LLM processing tasks, single FIFO delivery task, 이전 앱 추적(`lastExternalApp`), 스크린샷 캡처/선택 연동 |

## For AI Agents

### Working In This Directory
- `RecordingCoordinator`는 active recording과 queued jobs를 분리한다. `startRecording()`은 녹음만 시작하고, `stopRecording()`은 per-job snapshot/audio/context/screenshots를 `DictationQueueState`에 enqueue한다.
- `processPipeline()` 단일 함수/단일 `currentTask` 패턴으로 되돌리지 말 것. 현재 흐름은 `scheduleSTTJobs()` / `scheduleLLMJobs()` / `scheduleDelivery()`로 나뉜다.
- STT/LLM processing task는 provider별 permit(`DictationProviderConcurrencyPolicy`)이 허용하는 만큼 병렬 실행된다. STTProvider 자체는 NOT @MainActor이고 `await sttProvider.transcribe()`에서 백그라운드 추론한다.
- Delivery는 항상 단일 task이며 FIFO head job만 처리한다. `TextInsertionService.insertText()`/`insertImages()`와 `ScreenshotSelectionView`는 delivery 단계이며 녹음 중에는 시작/진행하지 않는다.
- `startRecording()`은 기존 screenshot selection/delivery를 pause하고, 녹음 종료 후 FIFO head부터 재개한다. audio start 실패 시 continuous capture/recording flag를 정리하고 scheduler를 다시 돌려야 한다.
- `cancel()` semantics: recording 중이면 현재 recording만 폐기; active delivery/selection이면 해당 job 하나만 terminal; processing overlay에서 ESC가 들어오면 foreground job 하나만 cancel. passive background 전체 queue 취소 금지.
- `lastExternalApp`은 `NSWorkspace.didActivateApplicationNotification`으로 추적 — 텍스트를 삽입할 대상 앱. 대상 context는 job별 snapshot으로 보존한다.
- Chrome 대상 + `restoreBrowserTab` 활성 시 `startRecording()`에서 `BrowserContextService.captureChrome`을 **MainActor 동기 호출** (NSAppleScript TCC 프롬프트 조건) → job targetContext에 저장. Delivery에서 `restoreChrome` 호출 후 `insertText`.
- iTerm2 대상 + `restoreTerminalContext` 활성 시 `TerminalContextService.captureITerm2` 동기 호출 → Delivery에서 `restoreITerm2`로 session(pane) + tmux `select-window`/`select-pane` 복원.
- VLM 활성(`isScreenshotContextEnabled` + `supportsVision`) 시 recording 동안 `ContinuousScreenCaptureService` 시작/중지. 교정/전달 단계에서 스크린샷이 있으면 FIFO delivery head에 대해서만 `ScreenshotSelectionView` 표시 → 사용자 선택 → 붙여넣기.
- `refreshProjectedState()`는 `.selectingScreenshots`를 덮어써서는 안 된다. 투영은 UI 상태(`appState.transcriptionState`)를 자기참조로 확인하지 말고 **큐 job status**(`.awaitingScreenshotSelection`)를 근거로 삼아야 한다. UI 상태를 자기 확인하면 `.selectingScreenshots`가 세팅되기 **전에** 가드가 평가되어 stale `.inserting`이 발행되고, `hideSelectionPanel()`이 그것을 "사용자가 선택 안 함"으로 오해해 pending continuation을 빈 배열로 해소한다. 이 결함은 `2ce542a2 feat: multi recording`에서 유입되어 스크린샷 첨부를 상시 실패시켰다. 참고: `appState.transcriptionState`는 dedup 없는 `@Published`이고, `AppDelegate`의 sink는 `.receive(on: DispatchQueue.main)`을 사용 — 이미 메인 스레드여도 **항상** 비동기로 enqueue되며 FIFO, coalescing 없음. 그래서 발행 순서가 그대로 레이스로 이어진다.

### Dependencies
- `AppState` (상태 읽기/쓰기)
- `AudioService` (녹음)
- `BrowserContextService` (Chrome 탭/element 캡처·복원)
- `TerminalContextService` (iTerm2 session + tmux pane 캡처·복원)
- `ContinuousScreenCaptureService` (스크린샷 캡처)
- `TextInsertionService` (결과 붙여넣기)
- STT/LLM Provider (AppState를 통해 간접 참조)

<!-- MANUAL: -->
