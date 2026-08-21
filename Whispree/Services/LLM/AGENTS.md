<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-23 | Updated: 2026-04-02 -->

# LLM

## Purpose
LLM 기반 텍스트 교정. 프로토콜 추상화로 None/LocalText/LocalVision/OpenAI/OpenAI 호환 간 런타임 전환. VLM 모델은 스크린샷 컨텍스트를 활용한 교정 지원.

## Key Files

| File | Description |
|------|-------------|
| `LLMProvider.swift` | `@MainActor protocol LLMProvider` — `correct(text:systemPrompt:glossary:screenshots:)`, `supportsVision` 프로퍼티 |
| `CorrectionPrompts.swift` | 교정 프롬프트 4가지 모드: `standard`(언어별 분기), `fillerRemoval`(필러 제거), `structured`(구조화), `custom`(사용자 정의). `screenshotContextPrompt`, `codeSwitchPrompt` |
| `LocalTextProvider.swift` | MLX 텍스트 전용 LLM — MLXLLM 프레임워크, 15초 타임아웃, `<think>` 블록 제거, word-edit-distance 안전장치 (threshold 0.5) |
| `LocalVisionProvider.swift` | MLX VLM — MLXVLM 프레임워크, 최대 3장 스크린샷 base64 인코딩, 30초 타임아웃, 500토큰 제한 |
| `NoneProvider.swift` | 패스스루 (교정 없음) |
| `OpenAIProvider.swift` | ChatGPT Responses API + SSE 스트리밍, `CodexAuthService` 토큰 재사용, vision 지원 |
| `OpenAICompatibleProvider.swift` | 범용 OpenAI 호환 Chat Completions (`POST {baseURL}/chat/completions`) — vLLM/Ollama/OpenRouter 등. base URL·API Key·모델 ID 자유 문자열, vision은 사용자 토글 |

## For AI Agents

### Working In This Directory
- `LLMProvider`는 `@MainActor` — STTProvider와 다름 (LLM은 가벼운 API 호출 + AppState 접근 필요)
- `LLMService.swift`는 **삭제됨** — word-edit-distance 로직은 `LocalTextProvider`/`LocalVisionProvider` 내부로 이동
- word-edit-distance가 0.5를 초과하면 교정 결과를 버리고 원본 반환 → 환각 방지 핵심 로직
- `CorrectionPrompts`는 **한국어** few-shot 예시 포함 — 프롬프트 수정 시 한국어/영어 코드스위칭 케이스 테스트
- `LocalVisionProvider`는 스크린샷을 `data:image/jpeg;base64,...` 형태로 변환하여 모델에 전달
- `OpenAIProvider`는 SSE 스트리밍 파싱 → `OpenAIModels.swift`의 응답 모델 참조
- `OpenAICompatibleProvider`는 non-streaming 단일 요청. 모델 ID가 자유 문자열이므로 enum 프로바이더(`OpenAIModel`/`GroqLLMModel`)와 달리 모델별 특수 파라미터(reasoning_effort 등) 없음

### Testing
- `WhispreeTests/Services/LLMServiceTests.swift` — word-edit-distance, LocalModelSpec, 프로바이더 속성, OpenAICompatibleProvider validate/live 스모크 (환경변수 기반)

<!-- MANUAL: -->
