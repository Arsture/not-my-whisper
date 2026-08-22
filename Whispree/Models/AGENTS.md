<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-06-09 -->

# Models

## Purpose
데이터 모델과 설정 타입 정의. Codable 설정, 도메인 단어 세트, 모델 정보, 전사/UI 상태, 병렬 dictation queue 상태 머신, 디바이스/모델 호환성 평가.

## Key Files

| File | Description |
|------|-------------|
| `AppSettings.swift` | `@MainActor final class: ObservableObject` — 3종 property wrapper로 각 필드를 `whispree.<fieldName>` 키에 **개별 저장**. 1회성 legacy blob(`"WhispreeSettings"`) 마이그레이션 내장. private `LegacyAppSettings`는 구 blob 디코드 전용 (건드리지 말 것) |
| `DictationQueue.swift` | `@MainActor` queue state machine — `DictationJob`, immutable job snapshot, provider concurrency policy, FIFO delivery gate, scoped cancellation, terminal cleanup/retention |
| `UserDefault.swift` | 3종 property wrapper: `@UserDefault` / `@RawRepresentableUserDefault` / `@CodableUserDefault`. `_enclosingInstance` static subscript로 ObservableObject 반응성 자동 처리 |
| `DomainWordSets.swift` | 도메인 특화 단어 세트 (프로그래밍, 의료 등) — STT promptTokens 주입 및 LLM glossary 용 |
| `ModelInfo.swift` | WhisperKit/LLM 모델 메타데이터 (이름, 크기, 상태) |
| `OpenAIModels.swift` | OpenAI API 응답 모델 (ChatCompletion, SSE 스트리밍 파싱) |
| `TranscriptionState.swift` | 상태 머신 enum — `idle → recording → transcribing → correcting → inserting → idle`, `ModelState` enum |
| `CapturedScreenshot.swift` | 녹음 중 캡처된 스크린샷 데이터 모델 — `Identifiable`, appName/timestamp/imageData |
| `DeviceCapability.swift` | Apple Silicon 하드웨어 감지 — chipName, totalRAMGB, memoryBandwidthGBs, gpuCores. `static let current` 싱글톤 |
| `LocalModelSpec.swift` | 지원 MLX 모델 레지스트리 — text(Qwen3 1.7B/4B/8B, Coder 30B, GLM-4.7) + vision(Qwen3 VL 4B). `ModelCapability` enum |
| `ModelCompatibility.swift` | 디바이스-모델 호환성 평가 (canirun.ai 방식) — `CompatibilityGrade` 6단계, RAM/속도 기반 점수 산출 |

## For AI Agents

### Working In This Directory

#### AppSettings 필드 추가 시 (CRITICAL)

**절대 struct + JSON blob 방식으로 되돌리지 말 것.** 과거에 그 방식이 Swift synthesized `init(from:)`의 `keyNotFound` throw 때문에 업데이트마다 전체 설정을 리셋시키던 버그를 근본 해결한 구조임 (기존 유저의 groqApiKey / correctionMode / domainWordSets 등이 매번 날아가던 문제).

`AppSettings(store:migrateHotkeys:)`의 store 주입은 테스트 격리 경계다. 앱은 기본 `.standard`를 사용하지만 테스트는 반드시 고유 `UserDefaults(suiteName:)`와 `migrateHotkeys: false`를 전달해야 한다. 테스트 호스트는 실제 앱과 같은 bundle ID로 실행되므로 `UserDefaults.standard`를 삭제하거나 테스트 값을 쓰면 사용자의 API key·온보딩 상태를 직접 손상시킨다.

필드 추가 절차:

1. 타입에 맞는 wrapper 한 줄 선언:
   ```swift
   @UserDefault(key: "whispree.newField", defaultValue: false)
   var newField: Bool

   @RawRepresentableUserDefault(key: "whispree.newEnum", defaultValue: .caseA)
   var newEnum: SomeEnum   // enum은 이쪽

   @CodableUserDefault(key: "whispree.newList", defaultValue: [])
   var newList: [SomeCodableStruct]   // Codable 복합 타입은 이쪽
   ```
2. `save()` 호출 **절대 금지** — wrapper setter가 자동 저장. AI가 "save() 호출이 누락된 것 같다"고 판단하고 추가하지 말 것.
3. 기본값은 wrapper 파라미터로. struct declaration의 `var x = default` 문법은 wrapper에 영향 없음.
4. enum의 rawValue를 바꿔야 할 때: 옛 rawValue를 **삭제하지 말고** `rawAliasMap`에 매핑 추가:
   ```swift
   @RawRepresentableUserDefault(
       key: "whispree.correctionMode",
       defaultValue: .standard,
       rawAliasMap: ["promptEngineering": "fillerRemoval"]
   )
   ```
5. 필드 제거 시: wrapper 선언만 삭제. UserDefaults 키는 자연 방치 (orphan key는 무해). 필요하면 `migrateLegacyBlobIfNeeded()` 옆에 one-off cleanup 추가.

#### Collection in-place mutation 금지

`@CodableUserDefault`가 감싼 컬렉션은 static subscript가 **value를 반환**하므로 in-place mutation이 저장되지 않음. 반드시 copy-mutate-reassign:

```swift
// ❌ 저장 안 됨 (silent failure)
settings.domainWordSets[i].words.append(word)

// ✅ copy-mutate-reassign
var sets = settings.domainWordSets
sets[i].words.append(word)
settings.domainWordSets = sets
```

SwiftUI Binding도 동일한 이유로 `$settings.domainWordSets[i]` projection 대신 수동 `Binding(get:set:)` 사용. 참고 구현: `Views/Settings/DomainWordSetsView.swift`, `Services/QuickFix/QuickFixService.swift`.

#### 기타 모델 파일

- `TranscriptionState`는 global UI projection일 뿐 per-job source of truth가 아니다. Multi-recording 상태/순서/permit은 `DictationQueueState`/`DictationJobStatus`가 소유한다. 상태 추가 시 UI projection(`RecordingCoordinator.refreshProjectedState`)과 queue tests를 같이 확인.
- `DomainWordSets`는 STT Provider의 `promptTokens`와 LLM Provider의 `glossary`에 매핑
- `DeviceCapability` + `LocalModelSpec` + `ModelCompatibility`가 "Can I Run" 시스템 구성 — 모델 추가 시 세 파일 모두 확인
- `LocalModelSpec.supported` 배열에 모델 추가 시 `minMemoryGB`, `qualityScore` 설정 필수

#### DictationQueue invariants

- Queue admission에는 작은 고정 cap을 두지 않는다. 메모리 안전은 terminal cleanup/retention/resource warning으로 다룬다.
- Provider별 concurrency permit은 `DictationProviderConcurrencyPolicy`와 provider별 permit dictionary가 source of truth다. 별도 전역 counter를 추가해 혼합하지 말 것.
- FIFO delivery: later job이 먼저 ready여도 earlier non-terminal job이 끝나기 전에는 삽입하지 않는다. failed/canceled/skipped terminal job은 FIFO를 unblock해야 한다.
- Terminal transition은 STT/LLM permit release, active delivery clear, audio/screenshots/selected images/target context cleanup을 수행해야 한다.
- Late provider completion이 canceled/terminal job을 resurrect하면 안 된다.

### Testing
- `WhispreeTests/Models/AppSettingsTests.swift` — 설정 직렬화/역직렬화 + CorrectionMode 마이그레이션
- `WhispreeTests/Models/DomainWordSetsTests.swift` — 도메인 단어 세트
- `WhispreeTests/Models/DictationQueueTests.swift` — queue ordering/concurrency/FIFO/cancellation/cleanup state machine
- `WhispreeTests/Services/LLMServiceTests.swift` — LocalModelSpec 검증

<!-- MANUAL: -->
