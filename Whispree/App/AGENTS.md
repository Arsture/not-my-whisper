<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-08-08 -->

# App

## Purpose
앱 진입점과 전역 상태 관리. SwiftUI App lifecycle, AppDelegate, 중앙 상태(`AppState`), 상수 정의.

## Key Files

| File | Description |
|------|-------------|
| `WhispreeApp.swift` | SwiftUI `@main` 진입점, Scene 구성 |
| `AppDelegate.swift` | NSApplicationDelegate — 메뉴바 아이콘, 핫키, 윈도우 관리, Quick Fix 조율 |
| `AppState.swift` | `@MainActor ObservableObject` 중앙 상태 — projected 전사 상태, dictation queue snapshot, 프로바이더, 오디오 레벨, 설정, 히스토리, 스크린샷 캡처 |
| `Constants.swift` | 앱 전역 상수 (모델명, URL, 기본값 등) |

## For AI Agents

### Working In This Directory
- `AppState`는 **모든 View와 Service가 참조**하는 중앙 상태. 프로퍼티 변경 시 영향 범위를 반드시 확인
- `transcriptionState`는 multi-job source of truth가 아니라 UI projection이다. 실제 queue/order/cancel state는 `DictationQueueState`가 소유하고 `dictationQueueSnapshot`으로 UI에 노출된다.
- `AppState`는 `@MainActor` — UI 스레드에서만 접근
- Provider 전환 로직(`switchSTTProvider`, `switchLLMProvider`)이 여기에 있음
- `AppState`에 스크린샷 관련 상태: `capturedScreenshots`, `screenshotSelectionCallback`, `previewRequestCallback`. Callback은 FIFO delivery head job에만 대응해야 하며 ESC/recording suspend 시 exactly once로 정리되어야 한다.
- `AppDelegate`는 lifecycle 관리 — NSStatusItem(메뉴바 아이콘) + NSWindow(메인 윈도우). Dock 아이콘/Cmd+Tab 앱 전환기 노출은 **고정된 `LSUIElement=false`가 아니라 동적 `NSApplication.ActivationPolicy` 전환**으로 제어한다: 메뉴바 아이콘은 항상 존재하고, 아래 predicate에 해당하는 윈도우/패널이 하나라도 보이면 `.regular`로 전환해 Dock 아이콘과 Cmd+Tab 항목을 노출하며, 전부 닫히면 `.accessory`로 돌아가 메뉴바 전용 상태가 된다. Spotlight 검색 가능 여부는 Launch Services 인덱싱에 좌우되며 activation policy와는 독립적이므로 이 전환에 영향받지 않는다.

  Dock 가시성 predicate (windowOrPanel → counts toward Dock visibility):

  | Window/panel | Dock 가시성에 반영 |
  |---|---|
  | `mainWindow` | YES |
  | `onboardingWindow` | YES |
  | `overlayPanel` (녹음 HUD) | NO |
  | `selectionPanel` (스크린샷 선택) | NO |
  | `previewPanel` | NO |
  | `quickFixPanel` | NO |

  원칙: **백그라운드 dictation queue의 산출물(오버레이/선택/프리뷰/QuickFix 패널)은 activation policy를 절대 좌우하지 않는다** — 여기에 연동하면 연속 받아쓰기 중 Dock 아이콘이 깜빡이게(strobe) 된다.

  `.accessory` 상태는 macOS 특성상 **메뉴바 자체가 없다** — 이 상태에서 앱을 종료하려면 메뉴바 아이콘 클릭 → 창 열림 → Cmd+Q의 2단계 경로를 거쳐야 한다. 알려진, 의도된 트레이드오프.

### 기존 Activation 코드를 "정리"하지 말 것
기존 `NSApp.activate(ignoringOtherApps:)` 호출들과 `mainWindow.level` 억제(`.normal - 1`)는 `c1ee63a3`(2026-04-10, *"파이프라인 중 메인 윈도우가 포커스를 가로채는 문제 해결"*)이 도입한 억제 장치다. macOS 14+에서 `activate(ignoringOtherApps:)`가 deprecated이고 플래그가 무시되지만 **무시 ≠ 무효** — 이 커밋의 존재 자체가 해당 호출들이 실제로 성공해 창을 끌어올린 전력의 증거다. 현재의 focus 안정성은 이 억제 장치들이 지탱하고 있으므로 실측 증거 없이 일괄 정리하지 말 것.

### Testing
- `AppState` 변경 시 `WhispreeTests/Models/` 테스트 확인
- Provider 전환 로직은 E2E 테스트(`PipelineE2ETests`)에서 검증

<!-- MANUAL: -->
