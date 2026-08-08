# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 필수 규칙: 빌드 & 배포 & 커밋

하나의 feature/fix가 완료되면 반드시 다음을 수행:

**배포는 반드시 Release 빌드로 한다.** Debug 빌드를 `/Applications`에 올리지 말 것 (이유는 아래). 디버거 attach가 필요하면 배포본이 아니라 Xcode에서 Debug 스킴으로 직접 실행한다.

### 배포 스크립트 (통째로 복붙)

```bash
set -e
APP=/Applications/Whispree.app
SYMBOL=someNewSymbol   # 이번 변경으로 새로 생긴 심볼/문자열. 옛 빌드 배포 방지용.

xcodebuild -project Whispree.xcodeproj -scheme Whispree \
  -configuration Release -destination 'platform=macOS,arch=arm64' build

pkill -9 -f "Whispree.app" 2>/dev/null || true; sleep 1

# ls -td (mtime 내림차순) 필수 — find|head 는 알파벳 순이라 옛 빌드를 집어온다
SRC=$(ls -td ~/Library/Developer/Xcode/DerivedData/Whispree-*/Build/Products/Release/Whispree.app | head -1)
rm -rf "$APP" && cp -R "$SRC" /Applications/

codesign --force --deep --sign "Whispree Signing" \
  --entitlements Whispree/Resources/Whispree.entitlements "$APP"

# 검증 3종
strings "$APP/Contents/MacOS/Whispree" | grep -c "$SYMBOL"          # 최신 빌드인가
codesign -d -r- "$APP" 2>&1 | grep designated                        # 서명 정체성 동일한가
codesign -d --entitlements - --xml "$APP" | plutil -convert xml1 -o - - | grep -c get-task-allow  # 0 이어야 함

open "$APP"; sleep 4
pgrep -f "Whispree.app/Contents/MacOS/Whispree" || {
  echo "기동 실패"; ls -t ~/Library/Logs/DiagnosticReports/Whispree*.ips | head -1; }
```

커밋은 feature/fix 단위로. 작업 도중에 중간 커밋하지 말 것 — 기능이 완결된 시점에만.

**첫 Release 빌드는 mlx-swift C++ 전체를 최적화 컴파일하느라 오래 걸린다.** 이후 증분 빌드는 빠르다. 백그라운드로 돌릴 때는 빌드 종료를 기다렸다가 배포까지 이어지게 `until ! pgrep -f "xcodebuild.*Release"; do sleep 5; done`로 체이닝할 것.

**`pgrep` 기동 확인을 생략하지 말 것.** `open`은 프로세스가 즉시 죽어도 성공을 반환하고 `codesign --verify`도 통과한다. 실제로 이 확인이 없어서 죽은 앱을 "배포 성공"으로 보고한 이력이 있다.

### 왜 Release인가 (Debug 배포가 만드는 문제 3종)

1. **권한 재요청**: Debug에는 Xcode가 `com.apple.security.get-task-allow`를 자동 주입한다. macOS TCC는 **디버거가 붙을 수 있는 앱에 Accessibility 권한을 영구 저장하지 않으므로** 배포할 때마다 프롬프트가 다시 뜬다. Release에는 없다.
2. **`--deep`이 `Contents/MacOS/*.dylib`을 서명하지 않는다**: Debug는 코드 대부분이 `Whispree.debug.dylib`에 있어서, 번들만 재서명하면 dyld가 `Library not loaded: @rpath/Whispree.debug.dylib ... different Team IDs`로 **기동 실패**한다. Release엔 이 dylib이 없다.
3. **자체 서명 인증서로 Debug를 재서명할 수 없다**: hardened runtime의 library validation이 Team ID 없는 서명을 거부한다. Release는 검증 대상 dylib이 없어 CI와 **같은 인증서로 서명 가능** → 로컬 배포본과 Sparkle 배포본이 TCC에 **동일한 앱**이 되어 권한을 한 번만 주면 된다.

**`-o runtime`을 붙이지 말 것.** hardened runtime은 library validation을 켜고, 이는 로드되는 프레임워크가 같은 Team ID로 서명됐을 것을 요구한다. `Whispree Signing`은 자체 서명이라 Team ID가 없어 `Sparkle.framework` 검증이 실패하고 앱이 `Library not loaded: @rpath/Sparkle.framework/...`로 죽는다. **`--entitlements`는 반드시 붙일 것** — 빼면 entitlements가 전부 날아간다(`--force`가 서명을 통째로 갈아엎기 때문).

### 권한 프롬프트가 계속 다시 뜰 때

TCC는 번들 ID가 아니라 **코드 서명 요구사항(csreq)** 으로 앱을 식별한다. 서명 정체성이 바뀌면 기존 허용 항목이 지금 바이너리와 매칭되지 않아, **System Settings에는 토글이 켜져 보이는데 실제로는 권한이 없는** 상태가 된다. 증상은 "허용해뒀는데 매번 다시 물어봄".

진단:
```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select service, hex(csreq) from access where client like '%whispree%';"
```
hex를 디코드해 나오는 인증서 CN이 현재 서명(`codesign -dv /Applications/Whispree.app`)과 다르면 stale이다.

해결 — 낡은 항목을 지우고 한 번만 다시 부여받는다:
```bash
pkill -9 -f "Whispree.app"
for svc in Accessibility AppleEvents ScreenCapture Microphone ListenEvent PostEvent; do
  tccutil reset "$svc" com.whispree.app
done
open /Applications/Whispree.app
```
서명 정체성을 고정해두면(위 절차대로 항상 `Whispree Signing`) 재배포·Sparkle 업데이트 후에도 권한이 유지되므로 이 초기화는 정체성을 바꿀 때만 필요하다.

## 공개 문서 사이트 (docs-site) & main 배포 게이트

- 공개 문서는 `docs-site/`에 nested Astro Starlight 앱으로 존재하며 Vercel **Root Directory = `docs-site`**로 배포된다. 정적(static) 출력 우선 — 무거운 런타임/SSR 도입 금지.
- **공개 docs는 철저히 사용자용**이다 — "Whispree로 무엇을 할 수 있고 어떻게 쓰는가"(기능 중심). 릴리스/기여 절차 같은 개발자 내부 문서는 공개 페이지로 만들지 말고 `docs-site/CONTRIBUTING.md`와 이 파일에 둔다.
- **이중언어(i18n)**: 한국어가 root 로케일(`src/content/docs/**`), 영어는 `/en/`(`src/content/docs/en/**`). 페이지 추가/수정 시 **양쪽 언어를 함께** 갱신한다.
- **main 배포 게이트 (필수)**: `dev` → `main` merge / 프로덕션 배포 / 릴리스 push 직전에 사용자 노출(기능·프로바이더·권한·단축키·워크플로우) 변경이 있으면 반드시 다음 중 하나를 수행:
  1. 해당 기능 페이지(`docs-site/src/content/docs/**`)와 영어 미러(`.../en/**`) 업데이트
  2. `docs-site/CONTRIBUTING.md`의 feature 페이지 템플릿으로 새 기능 페이지 추가(양 언어)
  3. 내부 전용 변경이면 커밋/handoff에 `No docs needed:` 사유 명시

  README만 고치는 것으로는 게이트를 통과하지 못함.
- 문서 디자인 SSoT는 `docs-site/DESIGN.md` (Vercel-inspired 토큰 스펙 + neon-waveform 시그니처). 루트 `DESIGN.md`는 macOS 앱 전용으로 분리 유지.
- 문서 검증: `pnpm --dir docs-site build`. nested Vercel 배포는 `docs-site/`에서 `vercel deploy --yes`(preview), 프로덕션은 의도적 릴리스 시에만 `vercel deploy --prod --yes`.

## Git 브랜치 전략

- **작업은 항상 `dev` 브랜치에서 수행.** 급한 hotfix를 제외하면 `main`에 직접 커밋하지 말 것.
- 커밋 후 별도 지시가 없으면 **`dev`에 커밋 + push까지만** 수행.
- **절대 `main`에 자의적으로 merge/push하지 말 것.** `main`은 배포 브랜치이므로 유저가 명시적으로 "배포해줘", "main에 merge해", "push해" 등 지시할 때만 `dev` → `main` merge 후 push. "커밋해"는 `dev` push만을 의미함.
- 커밋 전 현재 브랜치가 `dev`인지 확인. `main`이면 `dev`로 체크아웃 후 작업.

파일 추가/삭제 시 빌드 전 `xcodegen generate` 필수.

## 코드 서명 구조

**2단 구조다.** 빌드는 `project.yml`의 Automatic Signing(`DEVELOPMENT_TEAM: DRDT2F8525`, `Apple Development` 인증서)으로 하고, 배포 시 자체 서명 인증서 **`Whispree Signing`**(CN=Whispree Signing, O=Arsture, 2036년 만료)으로 갈아끼운다.

CI(`release.yml`)도 같은 인증서를 쓴다 — P12를 `SIGNING_CERTIFICATE_P12` secret으로 넣어 키체인에 import한 뒤 `codesign --force --deep --sign "Whispree Signing"` 실행. 로컬 배포도 같은 인증서를 쓰므로 **TCC가 로컬 빌드와 Sparkle 배포본을 동일한 앱으로 인식**한다(권한 1회 부여로 충분). ad-hoc(`--sign -`)이 아니다 — 과거 문서에 그렇게 적혀 있었으나 사실과 다르다.

**알려진 갭 — CI 배포본이 entitlements와 hardened runtime을 잃는다.** `release.yml`의 서명 명령에 `--entitlements`가 없어서, `--force`가 서명을 갈아엎을 때 결과물이 **entitlements 0개 + `flags=0x0(none)`**(hardened runtime 꺼짐)이 된다. 로컬에서 동일 명령을 재현해 확인함. `project.yml`은 `ENABLE_HARDENED_RUNTIME: "YES"`와 entitlements 3개를 지정하는데 배포 단계에서 유실되는 것.

지금 당장 기능이 깨지지는 않는다 — 앱이 sandbox를 쓰지 않고 hardened runtime도 함께 꺼져서 entitlement 게이트 자체가 작동하지 않기 때문이다. **문제는 함정으로 남는다는 점**: 누군가 보안 강화 차원에서 `-o runtime`을 추가하는 순간 entitlements가 없으니 AppleEvents가 **-1743으로 조용히** 죽고, 유저에겐 "붙여넣기가 그냥 안 되는" 것으로 보인다. 수정은 `--entitlements Whispree/Resources/Whispree.entitlements` 한 줄 추가(기능 변화 없음, 순수 방어). **`-o runtime`은 추가하면 안 된다** — 자체 서명 인증서는 Team ID가 없어 `Sparkle.framework` library validation에 걸려 앱이 기동하지 않는다. 되살리려면 Team ID가 있는 인증서가 필요하다.

**진단 함정**: Claude Code의 Bash 샌드박스는 키체인 접근을 막아서 `security find-identity`가 인증서를 일부만 보여주고, 서명 빌드가 `No signing certificate "Mac Development" found ... team ID "DRDT2F8525"`로 실패한다. 이걸 보고 "`project.yml`의 팀 ID가 틀렸다"거나 "xcodegen이 서명 설정을 날렸다"고 **오진하지 말 것** — 서명이 필요한 명령은 `dangerouslyDisableSandbox: true`로 실행해야 한다. 참고로 인증서 CN의 괄호 값(`Apple Development: name (XXXXXXXXXX)`)은 팀 ID가 아니라 인증서 ID이며, 팀 ID는 subject의 OU 필드에 있다.

## Build & Test Commands

```bash
# Generate Xcode project (required after changing project.yml or adding/removing files)
xcodegen generate

# Build
xcodebuild -project Whispree.xcodeproj -scheme Whispree -destination 'platform=macOS,arch=arm64' build

# Run all tests (48 tests, includes E2E with real WhisperKit model loading ~24s first run)
xcodebuild -project Whispree.xcodeproj -scheme Whispree -destination 'platform=macOS,arch=arm64' test

# Deploy to /Applications
cp -R "$(find ~/Library/Developer/Xcode/DerivedData/Whispree-*/Build/Products/Debug -name 'Whispree.app' -maxdepth 1)" /Applications/
```

Metal Toolchain may be needed: `xcodebuild -downloadComponent MetalToolchain`

## What This Is

macOS menu bar STT app. Record speech → WhisperKit transcribe → LLM correct → paste into previous app. Runs locally on Apple Silicon (macOS 14+, arm64 only). XcodeGen (`project.yml`) generates the `.xcodeproj`.

## Architecture

**Recording queue** (orchestrated by `RecordingCoordinator`):
```
Hotkey → AudioService (record + FFT) → [ContinuousScreenCaptureService (VLM 활성 시)]
  → DictationQueueState.enqueue(job snapshot + audio + target context + screenshots)
  → provider-bounded parallel STTProvider.transcribe()
  → provider-bounded parallel LLMProvider.correct(screenshots:)
  → FIFO serialized delivery: [ScreenshotSelectionView] → TextInsertionService.insertText()/insertImages()
```
Delivery is blocked while actively recording. Queue admission is logically uncapped; provider concurrency is bounded per provider.

**Quick Fix pipeline** (orchestrated by `AppDelegate` + `QuickFixService`):
```
Hotkey → QuickFixService.captureSelectedText() (Cmd+C) → QuickFixPanelView → replaceText() (Cmd+V) + addToDictionary()
```

**Central state**: `AppState` (@MainActor ObservableObject) — holds projected transcription state, queue snapshot, providers, settings, audio levels, history, captured screenshots. All Views observe this. Per-job truth lives in `DictationQueueState`, not only `TranscriptionState`.

**Provider abstraction**: Both STT and LLM use protocol-based providers switchable at runtime via `AppState.switchSTTProvider(to:)` / `switchLLMProvider(to:)`.

### STT Providers (`protocol STTProvider` — NOT @MainActor, runs off main thread)
- `WhisperKitProvider` — local CoreML+ANE, `whisper-large-v3-turbo`. Supports domain word → promptTokens injection
- `GroqSTTProvider` — Groq Cloud API, same model but server-side. Converts [Float] → WAV → multipart upload
- `MLXAudioProvider` — mlx-audio Python worker via stdin/stdout JSON pipe. Supports any mlx-audio STT model (default: Qwen3-ASR-1.7B-8bit)

### LLM Providers (`@MainActor protocol LLMProvider`)
- `NoneProvider` — passthrough, no correction
- `LocalTextProvider` — MLX text-only LLM via MLXLLM, 15s timeout, word-edit-distance safety (0.5 threshold), `<think>` block stripping
- `LocalVisionProvider` — MLX VLM via MLXVLM, 30s timeout, max 3 screenshots base64 encoding, 500 token limit
- `OpenAIProvider` — ChatGPT Responses API with SSE streaming. 인증 우선순위: (1) `CodexAuthService` (`~/.codex/auth.json`), (2) `OAuthService` (`~/.whispree/oauth.json`, PKCE 브라우저 로그인 fallback)

### Screenshot Capture
`ContinuousScreenCaptureService` (@MainActor) — VLM 활성 시 녹음 중 앱 전환/스크롤/클릭 감지 기반 디바운스 캡처 (1.5초 idle 후 캡처, 최대 20장). `ScreenCaptureService`가 CGWindowListCopyWindowInfo로 실제 윈도우 캡처. Screen Recording 권한 필요.

### Text Insertion
`TextInsertionService.insertText()` is async. Activates previous app → clipboard + CGEvent Cmd+V. Falls back to clipboard-only when no valid target app (e.g., recording from Settings window). Requires Accessibility permission (`AXIsProcessTrusted`).

### Hotkey System
`EventTapHotkeyService` — CGEventTap(cghidEventTap) 기반 전역 핫키, macOS 시스템 단축키보다 먼저 인터셉트. 단축키 녹화 모드 + 통합 ESC 핸들러. `ShortcutConflictDetector`로 53+ 알려진 시스템 단축키 충돌 감지.

### Device Compatibility ("Can I Run")
`DeviceCapability` (Apple Silicon 하드웨어 감지) + `LocalModelSpec` (MLX 모델 레지스트리: text 5개 + vision 1개) + `ModelCompatibility` (RAM/속도 기반 6단계 등급 평가). canirun.ai 방식의 호환성 점수 산출.

## Key Design Decisions

- **STTProvider is NOT @MainActor** — ML inference must run off main thread to avoid MainActor deadlock. WhisperKit/Groq providers are `@unchecked Sendable`.
- **LLMProvider IS @MainActor** — LLM calls are lighter and need AppState access.
- **TextInsertionService uses `Task.sleep` not `Thread.sleep`** — yields MainActor during waits.
- **`RecordingCoordinator` owns active recording + queued jobs** — do not revert to one `currentTask`/`processPipeline()` model. STT/LLM processing may run in parallel under provider permits; delivery is one FIFO task and is blocked while recording.
- **`lastExternalApp`** tracked in `RecordingCoordinator` via `NSWorkspace.didActivateApplicationNotification` — captures the app before Whispree to avoid pasting into Whispree itself.
- **Word-edit-distance safety** in `LocalTextProvider`/`LocalVisionProvider`: word-based Levenshtein, threshold 0.5. Prevents LLM hallucination from replacing the entire text.
- **LocalTextProvider vs LocalVisionProvider**: `LocalTextProvider`는 MLXLLM 텍스트 전용 (15초 타임아웃). `LocalVisionProvider`는 MLXVLM 비전 모델 (30초 타임아웃, 스크린샷 base64 인코딩). 둘 다 `LLMProvider` 프로토콜 구현.
- **CorrectionPrompts** are in Korean with few-shot examples. 4가지 모드: `standard` (언어별 분기), `fillerRemoval` (필러 제거), `structured` (구조화), `custom` (사용자 정의). `codeSwitchPrompt` handles Korean-English codeswitching (밸리데이션 → validation).
- **QuickFix** (`Ctrl+Shift+D`): 선택 텍스트 캡처 → 교정 단어/매핑 입력 → 대상 앱에 교체 삽입 + 도메인 사전에 자동 등록. `QuickFixService` + `QuickFixPanelView`.
- **AppleScript 호출은 반드시 MainActor에서 동기 실행** — `NSAppleScript.executeAndReturnError`의 TCC(Automation) 프롬프트는 메인 스레드에서만 표시됨. 백그라운드 스레드/`Task.detached`에서 호출하면 프롬프트가 조용히 차단되고 에러 `-1743`만 남음(유저에겐 아무 변화 없음). `BrowserContextService`와 `TerminalContextService`가 `@MainActor`인 이유. `RecordingCoordinator.startRecording()`에서도 `Task` 래핑 없이 동기 호출. 전제: `com.apple.security.automation.apple-events` entitlement + `NSAppleEventsUsageDescription` Info.plist 키 필수. 상세 가이드: `.omc/skills/applescript-tcc-mainactor-expertise.md`.
- **외부 앱 컨텍스트 복원 아키텍처** (`Whispree/Models/ExternalContext.swift`): `.app` / `.chromeTab` / `.iTerm2Session` sum type. `RecordingCoordinator.startRecording()`에서 frontmost 앱별로 캡처 서비스 분기(`BrowserContextService.isChrome` / `TerminalContextService.isITerm2`) → job targetContext에 저장 → FIFO delivery 단계에서 역분기 restore. 새 터미널/앱 지원 추가 시 enum case + capture/restore 분기 + AGENTS.md 업데이트.

## Settings Persistence

`AppSettings` (@MainActor final class: ObservableObject) — 각 필드를 `whispree.<fieldName>` 키에 **개별 저장**. 3종 property wrapper 사용: `@UserDefault` (plist 타입), `@RawRepresentableUserDefault` (enum, `rawAliasMap`으로 rawValue 마이그레이션 alias 지원), `@CodableUserDefault` (Codable 복합 타입).

**필드 추가 시 규칙**:
- wrapper 한 줄 선언만 하면 됨. `settings.save()` 호출 금지 (wrapper setter가 `objectWillChange.send()` + UserDefaults set을 자동 처리).
- **단일 JSON blob 방식으로 되돌리지 말 것** — Swift synthesized `init(from:)`가 struct default value를 무시하고 `keyNotFound` throw하는 함정 때문에 업데이트마다 전체 설정이 리셋되던 버그를 근본 해결한 구조.
- Collection in-place mutation 금지: `settings.domainWordSets[i].words.append(...)`는 wrapper에서 저장 안 됨. **copy-mutate-reassign** 패턴 필수 (`var sets = settings.domainWordSets; sets[i].words.append(x); settings.domainWordSets = sets`).
- enum rawValue 변경 시: 옛 rawValue를 `rawAliasMap`에 추가 (기존 유저 데이터 호환).
- 첫 부팅 시 1회성 `migrateLegacyBlobIfNeeded()`가 구 `"WhispreeSettings"` JSON blob을 자동으로 분해 저장 후 삭제.

## SPM Dependencies

- WhisperKit 0.9.0+ — STT (CoreML + Neural Engine); resolved package may be newer
- mlx-swift-lm (main branch) — local LLM/VLM inference (MLXLLM, MLXVLM, MLXLMCommon)
- KeyboardShortcuts 2.0.0+ — global hotkey
- LaunchAtLogin 1.0.0+ — login item
- Sparkle 2.6.0+ — 자동 업데이트 (appcast.xml via GitHub Pages)

## Audio & Visualization

`AudioService` captures at native sample rate, resamples to 16kHz mono for STT. Also computes 64-band FFT (Accelerate vDSP, voice-focused 80-3500Hz range) published as `frequencyBands` for the waveform view. `NeonWaveformView` renders slim rounded bars at 60fps with fast attack / slow decay smoothing.

## Concurrency Notes

- `AppState`, `RecordingCoordinator`, `DictationQueueState`, `AudioService`, `AppDelegate`, `ContinuousScreenCaptureService` — all `@MainActor`
- `WhisperKitProvider`, `GroqSTTProvider`, `MLXAudioProvider` — nonisolated (NOT @MainActor), `@unchecked Sendable`
- `EventTapHotkeyService`, `ScreenCaptureService` — nonisolated (NOT @MainActor)
- Audio tap callback runs on audio thread; dispatches to MainActor via `Task { @MainActor in ... }`
- Queue admission is logically uncapped; STT/LLM processing is provider-bounded and may run in parallel; delivery/text/image insertion is one FIFO task and is blocked while recording.

## Directory Documentation (AGENTS.md)

각 디렉토리별 상세 문서. 작업 영역에 따라 해당 파일을 참조:

- @AGENTS.md — 프로젝트 루트 (아키텍처 개요, 빌드, 설계 제약)
- @Whispree/AGENTS.md — 메인 앱 타겟 (dictation queue, delivery, 동시성 모델)
- @Whispree/App/AGENTS.md — 앱 진입점, AppState 중앙 상태
- @Whispree/Coordinators/AGENTS.md — RecordingCoordinator queue/delivery 오케스트레이션
- @Whispree/Models/AGENTS.md — 데이터 모델, 설정, 상태 enum, 디바이스/모델 호환성
- @Whispree/Services/AGENTS.md — 서비스 레이어 개요
- @Whispree/Services/Audio/AGENTS.md — 마이크 녹음 + FFT
- @Whispree/Services/Auth/AGENTS.md — Codex 토큰 재사용 + OAuth PKCE 인증
- @Whispree/Services/BrowserContext/AGENTS.md — Chrome 탭/element context 캡처·복원
- @Whispree/Services/Hotkey/AGENTS.md — 전역 단축키 + CGEventTap + 충돌 감지
- @Whispree/Services/LLM/AGENTS.md — LLM 교정 (None/LocalText/LocalVision/OpenAI)
- @Whispree/Services/ModelManagement/AGENTS.md — ML 모델 다운로드
- @Whispree/Services/QuickFix/AGENTS.md — Quick Fix (선택 텍스트 교정 + 사전 등록)
- @Whispree/Services/ScreenCapture/AGENTS.md — 스크린샷 캡처 (단일 + 디바운스 연속)
- @Whispree/Services/STT/AGENTS.md — STT 프로바이더 (WhisperKit/Groq/MLX Audio)
- @Whispree/Services/TerminalContext/AGENTS.md — iTerm2/tmux context 캡처·복원
- @Whispree/Services/TextInsertion/AGENTS.md — FIFO delivery text/image insertion
- @Whispree/Services/TextInsertion/AGENTS.md — 클립보드 + CGEvent 붙여넣기
- @Whispree/Views/AGENTS.md — SwiftUI UI 레이어
- @WhispreeTests/AGENTS.md — 유닛 + E2E 테스트
