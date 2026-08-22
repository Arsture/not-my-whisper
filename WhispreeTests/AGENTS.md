<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-06-09 -->

# WhispreeTests

## Purpose
유닛 테스트 + E2E 테스트. E2E는 실제 WhisperKit 모델 로딩 포함 (첫 실행 ~24초).

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Coordinators/` | RecordingCoordinator 테스트 (현재 비어있음) |
| `E2E/` | 전체 파이프라인 E2E 테스트 |
| `Models/` | AppSettings, DomainWordSets, DictationQueue state machine 테스트 |
| `Services/` | LLM 교정, word-edit-distance, 모델 스펙 테스트 |

## Key Files

| File | Description |
|------|-------------|
| `E2E/PipelineE2ETests.swift` | WhisperKit 모델 로딩 + 전사 + LLM 교정 + 프로바이더 전환 E2E |
| `Models/AppSettingsTests.swift` | 설정 Codable 직렬화/역직렬화 + CorrectionMode 마이그레이션 |
| `Models/DomainWordSetsTests.swift` | 도메인 단어 세트 로직 + 프롬프트 텍스트 빌딩 |
| `Models/DictationQueueTests.swift` | 병렬 dictation queue: admission, provider concurrency, FIFO delivery, recording block, scoped cancellation, terminal cleanup |
| `Services/AudioServiceTests.swift` | 오디오 캡처/리샘플링 (placeholder) |
| `Services/LLMServiceTests.swift` | LocalTextProvider word-edit-distance + LocalModelSpec 검증 + 프로바이더 속성 테스트 |

## For AI Agents

### Running Tests
```bash
xcodebuild -project Whispree.xcodeproj -scheme Whispree -destination 'platform=macOS,arch=arm64' test
```

### Working In This Directory
- E2E 테스트는 실제 모델을 다운로드/로딩 — CI에서 첫 실행 시 시간 소요
- `AppSettings`/`AppState` 테스트에서 `UserDefaults.standard` 사용 금지. 테스트 호스트가 production bundle ID로 실행되므로 고유 suite를 만들어 `AppSettings(store:migrateHotkeys: false)`로 주입하고 종료 시 해당 persistent domain만 제거한다.
- `LLMServiceTests`는 `LocalTextProvider.wordEditDistance()` 직접 테스트 (LLMService 삭제됨)
- `Coordinators/` 디렉토리는 현재 비어있음 — RecordingCoordinator integration 테스트 추가 가능 영역
- Queue/ESC/FIFO behavior 변경 시 최소 `DictationQueueTests`를 먼저 업데이트하고 `xcodebuild ... -only-testing:WhispreeTests/DictationQueueTests test`로 빠르게 검증
- 테스트 타겟은 `TEST_HOST`로 메인 앱에 주입됨 (unit test bundle)

<!-- MANUAL: -->
