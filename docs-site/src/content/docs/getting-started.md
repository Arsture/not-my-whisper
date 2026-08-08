---
title: 설치 & 첫 받아쓰기
description: Whispree를 설치하고, 권한을 켜고, 첫 음성 입력을 직전 앱에 넣어보기까지.
---

Whispree는 **macOS 14 이상 · Apple Silicon(arm64)** 에서 동작합니다. 처음 실행하면 5단계 온보딩이 권한과 엔진 설정을 안내합니다.

## 1. 설치

가장 간단한 방법은 **Homebrew**입니다.

```bash
brew tap Arsture/whispree && brew install --cask whispree
```

설치하면 메뉴바에 마이크 아이콘이 나타납니다. 메뉴바 아이콘은 항상 떠 있고, Dock 아이콘과 Cmd+Tab 앱 전환기 항목은 메인 윈도우가 열려 있을 때만 함께 나타났다가 창을 닫으면 사라집니다 — Spotlight에서 Whispree를 찾는 데는 영향이 없습니다. Whispree는 Apple Developer ID 공증(notarize)이 없지만, **Homebrew로 설치하면 Gatekeeper 차단을 자동으로 처리**하고 자동 업데이트도 연결되므로 가장 권장됩니다.

### 고급: 다른 설치 방법

**GitHub Releases (수동 다운로드)** — [GitHub Releases](https://github.com/Arsture/whispree/releases)에서 `.zip`/`.dmg`를 받을 수 있지만, 공증이 없어 macOS Gatekeeper가 차단합니다. 압축을 푼 뒤 아래로 한 번 해제하고 `/Applications`로 옮기세요(Homebrew는 이 과정을 자동 처리합니다):

```bash
xattr -cr Whispree.app
```

**소스 빌드 (개발자)** — 직접 빌드해서 쓰려면:

```bash
git clone https://github.com/Arsture/whispree.git
cd whispree
brew install xcodegen
xcodegen generate
open Whispree.xcodeproj   # Xcode에서 Cmd+R로 빌드/실행
```

SPM 의존성은 첫 빌드 시 자동 해결됩니다. 단, 로컬 Xcode 서명 빌드는 Sparkle 자동 업데이트가 동작하지 않습니다(`git pull` + 재빌드로 업데이트).

## 2. 권한 켜기

첫 실행 온보딩에서 필요한 권한을 안내합니다. 핵심은 두 가지입니다.

| 권한 | 왜 필요한가 | 없으면 |
| --- | --- | --- |
| **마이크** | 음성 녹음 | 녹음이 되지 않음 |
| **손쉬운 사용(Accessibility)** | 결과를 직전 앱에 붙여넣기(키 이벤트) | 클립보드 복사만 되고 자동 삽입 실패 |
| **화면 기록** | 화면 컨텍스트(비전) 캡처 | 비전 교정에 스크린샷이 안 들어감 |
| **자동화(Automation)** | 브라우저/터미널 컨텍스트 복원 | 해당 복원 기능만 동작 안 함 |

마이크·손쉬운 사용만 켜도 기본 받아쓰기는 완전히 동작합니다. 나머지는 해당 기능을 쓸 때만 필요합니다. 자세한 내용은 [권한](/reference/permissions/)을 참고하세요.

## 3. 엔진 고르기 (선택)

기본값만으로도 바로 쓸 수 있습니다.

- **STT(받아쓰기)**: 기본은 **WhisperKit**(로컬, 첫 사용 시 ~1.5 GB 다운로드). 빠른 클라우드를 원하면 **Groq**(API 키 필요).
- **AI 교정**: 기본은 **없음(원문 그대로)**. 다듬기를 원하면 로컬 MLX / OpenAI / Groq / Claude 구독 중 선택.

엔진은 설정의 STT·LLM 탭 또는 홈 대시보드에서 언제든 바꿀 수 있습니다. 자세히는 [STT 엔진](/features/stt/)과 [AI 교정](/features/correction/)을 참고하세요.

## 4. 첫 받아쓰기

1. 다른 앱(메모장, 에디터, 채팅창 등)의 입력란을 클릭해 둡니다.
2. **`Ctrl+Shift+R`** 을 누릅니다. (기본 단축키)
3. 짧게 한 문장 말합니다.
4. 다시 `Ctrl+Shift+R` 을 누르면(토글 모드) 받아쓰기가 끝나고, 결과가 **방금 그 입력란**에 들어갑니다.

녹음 중에는 파형 오버레이가 상태(녹음/변환/교정)와 단축키 배지를 보여줍니다. **ESC** 로 현재 작업만 취소할 수 있습니다.

## 5. 녹음 모드 — 누르기 vs 토글

설정 → 일반에서 두 가지 중 선택합니다.

- **눌러서 말하기(Push-to-Talk)** — *기본값*. 단축키를 **누르고 있는 동안** 녹음, 떼면 변환.
- **토글(Toggle)** — 한 번 눌러 시작, 다시 눌러 멈춤.

:::tip
단축키는 설정 → 일반에서 다시 지정할 수 있고, **수식 키 하나만**(예: 오른쪽 ⌥)으로도 지정 가능합니다. 시스템 단축키와 충돌하면 경고가 표시됩니다.
:::

## 그 밖의 기본 설정

설정 → 일반에서 켜고 끌 수 있는 편의 기능:

- **녹음 중 음악 일시정지** *(기본 켜짐)* — 녹음 시작 시 재생 중인 미디어를 멈췄다가 끝나면 재생.
- **무음 자동 스킵(VAD)** *(기본 켜짐)* — 말이 없는 구간을 건너뛰어 변환 속도를 높임.
- **로그인 시 실행** *(기본 꺼짐)* — macOS 로그인 시 자동 시작.

## 다음 단계

- [받아쓰기 & 멀티 녹음](/features/dictation/) — 여러 번 연속으로 말하고, 단축키/URL로 제어하기.
- [AI 교정](/features/correction/) — 필러 제거·구조화·코드스위칭 교정.
- [단어 사전 & Quick Fix](/features/dictionary/) — 자주 틀리는 단어를 즉석에서 고치고 등록하기.
