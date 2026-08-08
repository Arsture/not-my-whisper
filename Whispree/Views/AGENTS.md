<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-08-08 -->

# Views

## Purpose
SwiftUI 뷰 레이어. 대시보드, 설정, 온보딩, 전사 오버레이, Quick Fix UI, 스크린샷 선택.

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Dashboard/` | 메인 대시보드 뷰 — `MainDashboardView.swift` |
| `Design/` | 디자인 토큰 + 공통 UI 컴포넌트 — DesignTokens, SettingsCard, StatusBadge, CompatibilityBadge, ModelMetricsView |
| `Onboarding/` | 초기 설정 플로우 — `OnboardingView.swift` |
| `QuickFix/` | Quick Fix 패널 — `QuickFixPanelView.swift` (단어/매핑 교정 입력) |
| `Settings/` | 설정 탭 뷰 — General, STT, LLM, Model, DomainWordSets, ShortcutRecorder |
| `Transcription/` | 전사/queue 오버레이 + 히스토리 — `TranscriptionOverlayView.swift`, `TranscriptionHistoryView.swift` |

## Key Files

| File | Description |
|------|-------------|
| `UnifiedView.swift` | 메인 윈도우 — 사이드바 네비게이션(Home/Settings/History) + 디테일 뷰 |
| `ScreenshotSelectionView.swift` | 스크린샷 선택 모달 — 키보드 네비게이션(↑↓/Space/Enter/Esc), 썸네일 + 타임스탬프 |

## Key Files (Design/)

| File | Description |
|------|-------------|
| `DesignTokens.swift` | 색상, 폰트, 간격 등 디자인 토큰 |
| `SettingsCard.swift` | 설정 카드 컨테이너 |
| `SettingsRow.swift` | 설정 행 컴포넌트 |
| `StatusBadge.swift` | 상태 표시 뱃지 |
| `CompatibilityBadge.swift` | 모델 호환성 등급 캡슐 뱃지 — CompatibilityGrade별 색상 매핑 |
| `ModelMetricsView.swift` | 모델 메트릭 표시 — 크기, RAM%, tok/s, 레이턴시, 품질 점수 |

## Key Files (Settings/)

| File | Description |
|------|-------------|
| `SettingsView.swift` | 설정 탭 컨테이너 |
| `GeneralSettingsView.swift` | 일반 설정 (핫키, 시작 시 실행 등) |
| `STTSettingsView.swift` | STT 프로바이더 선택 + 모델 메트릭 표시 |
| `LLMSettingsView.swift` | LLM 프로바이더 선택, 모델 선택(text/vision), 스크린샷 컨텍스트 토글, 교정 모드, OpenAI 인증 |
| `ModelSettingsView.swift` | 모델 다운로드/관리 + 디바이스 정보 + Can I Run 호환성 |
| `DomainWordSetsView.swift` | 도메인 단어 세트 편집 |
| `ShortcutRecorderButton.swift` | 단축키 녹화 버튼 — EventTapHotkeyService 연동, 충돌 감지 팝오버 |

## For AI Agents

### Working In This Directory
- 모든 뷰는 `AppState`를 `@EnvironmentObject`로 관찰
- `NeonWaveformView`(전사 오버레이)는 `frequencyBands` 기반 60fps 애니메이션 — 성능 민감
- Settings 뷰는 `AppSettings` 모델과 1:1 매핑 — 설정 필드 추가 시 뷰도 함께 수정
- `ScreenshotSelectionView`는 `AppState.screenshotSelectionCallback` 통해 FIFO delivery head job의 선택 결과만 전달
- `ModelMetricsView`와 `CompatibilityBadge`는 STT/LLM/Model 설정 뷰에서 재사용
- NSStatusItem(메뉴바 아이콘) + NSWindow(메인 윈도우) 패턴 사용. MenuBarExtra 미사용
- 병렬 processing UI는 calm count 중심이어야 한다: 여러 spinner/job detail로 attention을 빼앗지 말고 `dictationQueueSnapshot`의 active/processing/ready count를 노출한다.
- ESC cancel affordance는 명시 scope가 있을 때만 보여준다. Processing foreground item은 overlay의 `Cancel #N esc` 같은 표시가 있을 때만 전역 ESC scope가 된다.

### Palette / Color Usage Rules
- 색 사용의 최상위 근거 문서는 `Whispree/Views/Design/DESIGN-ROLE-HIERARCHY.md` 다. token 선택 전에 먼저 해당 요소의 역할이 구조(surface) / 상호작용(accent) / 의미(semantic) / 텍스트 위계 중 무엇인지 판단한다.
- 색상은 기본적으로 `DesignTokens`에서만 가져온다. 새로운 화면에서 raw `Color.red`, `Color.blue`, 임의 `opacity` 조합을 직접 추가하지 말고 먼저 토큰/공통 컴포넌트를 확장한다.
- 예외는 좌측 사이드바 네비게이션 accent 계열이다. 사이드바의 멀티컬러 아이콘/선택 강조는 유지할 수 있지만, content 영역(대시보드 카드·설정 패널·메트릭)은 제한된 palette로 수렴해야 한다.
- content 영역의 기본 규칙은 **중립 surface + 단일 accent + semantic status**다.
  - Surface: `surfaceBackground`, `cardBackground` 같은 중립 배경/보더
  - Accent: 선택, focus, CTA 등 인터랙션 강조
  - Semantic: success/warning/error/info 같은 상태 표현
- hierarchy는 color보다 spacing / grouping / typography / material에서 먼저 만들어야 한다. color는 마지막 보강 수단이어야 한다.
- 상태 색상은 `StatusBadge`, `CompatibilityBadge`, `ModelMetricsView` 같은 공통 표현에서만 우선적으로 사용한다. 본문 카드 배경을 상태별 무지개 tint로 분기하지 않는다.
- 새 색이 필요하면 먼저 "기존 semantic/accent/surface 토큰으로 해결 가능한가?"를 확인한다. 해결 불가 시 `DesignTokens.swift`에 중앙 정의를 추가하고, 재사용 지점을 함께 정리한다.
- 색상 변경 시 목표는 "모던한 느낌 유지"이지 "색상 다양성 증가"가 아니다. content 영역은 대비/위계 중심으로 정리하고, 장식용 색상은 최소화한다.

<!-- MANUAL: -->
