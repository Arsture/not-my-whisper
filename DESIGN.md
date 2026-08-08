# Design

## Source of truth
- Status: Implemented baseline; keep updated as product design source of truth
- Last refreshed: 2026-06-09
- Primary product surfaces: macOS menu bar app, floating transcription overlay, screenshot selection panel, settings/dashboard.
- Evidence reviewed:
  - `README.md` — Whispree promises fast voice-to-prompt, focus restoration, visual context, and code-switching correction.
  - `docs/PLAN.md` — latency risk already lists optimistic insertion / async correction as mitigation.
  - `Whispree/Coordinators/RecordingCoordinator.swift` — active recording is separated from queued dictation jobs; STT/LLM processing is provider-bounded and delivery is one FIFO task.
  - `Whispree/Services/Hotkey/HotkeyManager.swift` — toggle mode follows `appState.isRecording`, and ESC is scoped to preview/recording/active delivery/visible foreground item.
  - `Whispree/Models/DictationQueue.swift` — per-job snapshots/statuses, provider concurrency policy, FIFO delivery gate, cancellation/cleanup invariants.
  - `Whispree/Models/TranscriptionState.swift` — global projected UI state; per-recording/job truth lives in `DictationQueueState`.
  - `Whispree/Views/Transcription/TranscriptionOverlayView.swift` — overlay communicates active recording, calm processing count, and explicit `Cancel #N esc` foreground affordance.
  - `Whispree/Views/Design/DESIGN-ROLE-HIERARCHY.md` — UI should stay calm, semantic, hierarchy-first, and not visually compete with content.

## Brand
- Personality: calm, fast, invisible-until-needed, developer-native, macOS-native.
- Trust signals: precise state feedback, safe fallback to raw STT, predictable insertion target, no hidden destructive replacement.
- Avoid: noisy job dashboards, surprising focus steals, color-heavy progress UI, modal interruptions during speaking.

## Product goals
- Goals:
  - Let users keep speaking while previous utterances are being transcribed/corrected.
  - Preserve “talk instead of type” flow even when LLM correction is slow.
  - Make every pending utterance understandable and cancelable without demanding attention.
- Non-goals:
  - Reducing LLM latency itself.
  - Running unlimited local LLM jobs on constrained Apple Silicon.
  - Turning Whispree into a full task manager.
- Success signals:
  - A second recording can start immediately after the first recording stops, even while first LLM correction is pending.
  - Finished outputs insert in a predictable order/target.
  - User can see “N pending” and cancel individual pending work.

## Personas and jobs
- Primary personas: Korean/English code-switching developers using Cursor, Claude, ChatGPT, terminals, and browsers.
- User jobs:
  - Rapidly dictate multiple prompts or notes without waiting for correction.
  - Attach relevant visual context while moving across windows.
  - Keep cursor/focus intent stable even if they switch apps during background processing.
- Key contexts of use: prompt input fields, code editors, browser chats, terminal AI CLIs, long-form planning.

## Information architecture
- Primary navigation: existing dashboard/settings remain unchanged.
- Core routes/screens: floating overlay gains pending-job awareness; dashboard/history can expose recent job status.
- Content hierarchy:
  1. Current recording state.
  2. Pending background processing count.
  3. Last completed insertion/copy status.
  4. Optional details only on expansion/menu.

## Design principles
- Principle 1: The hotkey should stay record-first. Background processing must not block capture unless hardware/provider limits require it.
- Principle 2: Insert results predictably. Default to FIFO insertion per captured target context; never paste into the current app unless explicitly configured.
- Principle 3: Be calm by default. Show one compact pending indicator, not a stack of spinners.
- Principle 4: Degrade safely. If full parallel correction is unsafe, still allow queued recordings and process them sequentially.
- Tradeoffs: More concurrency increases throughput but risks memory pressure, rate limits, target-app focus churn, and confusing insertion order.

## Visual language
- Color: use existing semantic tokens; warning for backlog/slow queue, accent for active recording, success for completion.
- Typography: compact captions in overlay; detailed job labels only in expanded surfaces.
- Spacing/layout rhythm: keep overlay width near current compact form; avoid list expansion while recording.
- Shape/radius/elevation: follow existing material overlay and card surfaces.
- Motion: subtle progress/pulse only for active recording/current processor; avoid multi-spinner noise.
- Imagery/iconography: mic for recording, clock/queue for pending, checkmark for inserted/copied, exclamation for failed.

## Components
- Existing components to reuse: `TranscriptionOverlayView`, dashboard transcription/history sections, design tokens.
  - 메뉴바 진입점은 `AppDelegate`의 `NSStatusItem`이며 전용 SwiftUI 뷰가 없다. 과거 `MenuBarView`가 있었으나 어디에도 연결되지 않은 죽은 코드여서 제거했다(2026-08-08).
- New/changed components:
  - `RecordingJob`/`TranscriptionJob` status model.
  - Compact pending badge in overlay/menu bar.
  - Optional expanded “Processing queue” popover/list in dashboard or menu.
- Variants and states:
  - Recording while `N` jobs processing.
  - Processing queued/running/done/failed/canceled.
  - Inserted vs copied-to-clipboard fallback.
  - Screenshot selection required.
- Token/component ownership: UI state should be driven by `dictationQueueSnapshot`/job statuses. `TranscriptionState` is only the compact projected state for existing views.

## Accessibility
- Target standard: macOS-native keyboard accessible controls; do not rely on color alone.
- Keyboard/focus behavior:
  - Recording hotkey remains available during background processing.
  - `Esc` behavior should be scoped: during recording cancels current recording; in expanded queue can cancel selected job; global `Esc` should not accidentally cancel all jobs.
- Contrast/readability: pending count and errors must have text labels/icons.
- Screen-reader semantics: expose job count and current state as concise labels.
- Reduced motion and sensory considerations: no repeated flashing for multiple completions.

## Responsive behavior
- Supported breakpoints/devices: macOS desktop only.
- Layout adaptations: compact overlay always; expanded queue only in popover/dashboard.
- Touch/hover differences: mouse hover can reveal details, but all controls need keyboard/menu equivalents.

## Interaction states
- Loading: “Recording… · 2 processing” while speaking; “Correcting 1/3” when idle and queue remains.
- Empty: no pending jobs shown.
- Error: failed job remains in queue/history with “copy raw”, “retry correction”, “dismiss”.
- Success: brief non-intrusive completion pulse/toast; auto-hide.
- Disabled: if provider concurrency is unavailable, show “Queued” rather than blocking recording.
- Offline/slow network: jobs may queue or fall back to raw STT based on provider policy.

## Content voice
- Tone: terse, operational, confidence-building.
- Terminology: use “Recording”, “Processing”, “Queued”, “Inserted”, “Copied”, “Failed”. Avoid technical “LLM task” in primary UI.
- Microcopy rules: always say what happened and where the text went when insertion fallback occurs.

## Implementation constraints
- Framework/styling system: SwiftUI + existing design tokens.
- Design-token constraints: follow `Whispree/Views/Design/DESIGN-ROLE-HIERARCHY.md`; structure and typography before color.
- Performance constraints:
  - STT providers are intentionally not `@MainActor`; LLM providers are currently `@MainActor`.
  - `RecordingCoordinator` must keep active recording, provider-bounded processing tasks, and single FIFO delivery task separate. Do not reintroduce one `currentTask` pipeline.
  - Text insertion uses pasteboard and target app activation, so concurrent insertion must remain serialized.
  - Local LLM/STT concurrency is bounded by `DictationProviderConcurrencyPolicy` to avoid memory/GPU contention.
- Compatibility constraints: preserve browser/iTerm context restoration and screenshot selection semantics per job.
- Test/screenshot expectations:
  - Unit tests for job state transitions and queue ordering (`DictationQueueTests`).
  - Coordinator/integration tests for “record while previous job correcting” when seams are introduced.
  - UI tests or view-model tests for pending badge and cancel semantics.

## Open questions
- [x] Default delivery waits for corrected/fallback text and inserts FIFO; raw-immediate-replace is deferred.
- [x] Multiple completed jobs insert automatically FIFO, but delivery is blocked during active recording. Stale target confirmation remains a future safety enhancement.
- [ ] What is the maximum safe local-concurrency limit per provider/device? Owner: engineering. Impact: memory and reliability.
