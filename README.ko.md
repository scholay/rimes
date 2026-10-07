# RIMES

[![中文](.github/readme/labels/zh.svg)](README.md) [![English](.github/readme/labels/en.svg)](README.en.md) [![日本語](.github/readme/labels/ja.svg)](README.ja.md) [![한국어](.github/readme/labels/ko.svg)](README.ko.md) [![Español](.github/readme/labels/es.svg)](README.es.md)

위대한 오픈 소스 정신에 경의를 표합니다. 이 프로젝트의 중국어 입력 로직은 [RIME 입력기 엔진](https://rime.im/)을 기반으로 합니다.
여러 운영체제를 지원하는 입력기입니다. 사용자의 쓰임을 받는 세 개의 독창적인 슬롯이 있습니다. 1. 확정 전의 명시적 버퍼(Buffer) 2. 클립보드 기록, 화면 캡처, 개인 지식 베이스를 다루는 기억 캡슐(Capsule) 3. 바깥에서 들어오는 정보를 받는 대화 창(Mailbox).

완전 병음, 이중 병음, 성필(声笔), 오필, 영어 방안을 지원하고, 속기의 병격 입력과 사용자 방안 가져오기도 지원합니다. 처음 쓰는 사람을 위해 설치 패키지는 librime과 사전을 **함께 담아** 바로 쓸 수 있습니다.

> **RIMES**는 이 프로젝트의 아키텍처 이름입니다. 대외 제품명은 영어 **Lingxi IME**, 중국어 간체 **灵犀输入法**, 중국어 번체 **靈犀輸入法**입니다. iOS App Store에서도 이미 이 제품명을 사용하고 있습니다.

## 시연 영상

- [Bilibili · 전체 소개](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin · 제품 시연](https://www.douyin.com/video/7671078195197742355)

## 무엇을 해결하는가

입력기 하나로 번역, 생성, 다듬기 같은 일상 작업을, 지금 쓰는 앱을 떠나지 않고 처리합니다. 입력기와 플러그인이 맡습니다.

- **Buffer**(`⌘⇧B`): 확정 전의 텍스트 작업대. 중국어와 영어는 먼저 버퍼로 들어갑니다. 실시간 번역을 하거나, 고른 AI 연결기로 생성하고 고칠 수 있습니다. 확인한 뒤에야 현재 입력칸으로 **명시적으로 전달**합니다.
- **Capsule**(`⌘⇧V`): 화면 아래의 막대. 방금 복사한 텍스트, 링크, 이미지, 파일, 색은 「최근」에 나타납니다. 오래 남길 것은 노트, 이미지, PDF, 스킬, 비밀번호로 넣습니다.
- **Mailbox**(`⌘⇧M`): AI 대화, 메모, 검토를 기다리는 외부 알림은 이 창에 남습니다. 새 대화를 만들고 이미 설정한 연결기를 고를 수 있습니다.

## 주요 기능에 대해

> 설치를 마치고 그래픽 로그인 세션에 들어가면, 한 번의 백그라운드 작업이 `open -g`로 같은 RIMES 프로세스를 띄웁니다. 그래서 Buffer, Clipboard History, Mailbox, Capsule의 전역 단축키는 어떤 입력기에서나 쓸 수 있습니다.
>
> 배포 패키지는 시스템 payload를 바꾸기 전에 이 Mac의 일반 계정을 모두 점검합니다. postinstall이 물러나게 할 수 있는 현재 GUI 사용자의 개발판을 빼고, 같은 ID의 개발판 앱이나 작업이 있거나 home을 안전하게 확인할 수 없으면 바로 실패합니다. postinstall이 개발판을 물러나게 하고 다시 점검한 뒤에야, 되돌릴 수 있는 트랜잭션으로 시스템 작업을 갱신합니다. 로그인 guard는 나중에 나타난 개발판 흔적만 방어적으로 막습니다. 두 작업 모두 `KeepAlive`를 두지 않으며, 두 번째 UI/IME 서비스도 시작하지 않습니다.
>
> Mailbox와 Capsule은 키보드 포커스를 보통의 방식으로 받는 관리 창입니다. 다른 입력기에서 단축키나 Mailbox 알림으로 열면, RIMES가 먼저 자신을 현재 입력기로 바꾼 다음 엽니다. 닫을 때 되돌리지 않으며, 이후에 직접 다른 입력기로 바꿔도 그 선택은 취소되지 않습니다. 그때는 아래에 적힌 대로 기능이 제한됩니다.
>
> 이 기능들은 다른 입력기의 IMK 클라이언트에 접근하지 않고, 그 조합 중인 문자열을 읽거나 확정하거나 취소하지 않습니다. 넣는 키는 Capsule을 활성화할 때의 선택적 `⌘V` 한 번뿐입니다(아래 Capsule 막대 참고). 설정의 단축키도 입력기를 넘어 쓸 수 있습니다. Mailbox와 Capsule 페이지는 설정과 상태만 보여 주고, 실제 대화와 내용은 각자 창에 둡니다.

| 기능 | 단축키 | 내용 | 조작 | 저장 | 경계 |
|---|---|---|---|---|---|
| 입력 방안 | — | Rime Ice 완전 병음, 자연마, 소학, 오필 86, 영어 | — | — | — |
| 버퍼 | `⌘⇧B` | 확정 전의 텍스트 | 먼저 RIMES로 전환한 뒤 잡아 나누어 전달 | — | 다른 입력기로 옮긴 뒤에는 시스템 클립보드만 쓰고 IMK는 쓰지 않음 |
| Capsule 막대 | `⌘⇧V` | 최근 복사. 노트, 이미지, PDF, 스킬, 비밀번호 | 클릭은 선택, 더블 클릭 또는 Return은 붙여넣기. `⌘S`로 보관 | 이 Mac에만 | 붙여넣기에는 손쉬운 사용 권한이 필요. 없으면 클립보드에만 넣음 |
| Mailbox | `⌘⇧M` | AI 대화, 메모, 검토 대기 알림 | 새 대화. 첫 Return에 생성 시작 | 모델은 그 대화에만 묶임 | CLI는 각자 기본 모델 |
| Capsule 관리 | 톱니 또는 붓 | 다섯 종류. 미리보기와 복사 | 네 번의 병격 뒤에 비밀번호를 봄. 최대 15초 | iCloud는 선택. 비밀번호와 키는 이 Mac에 남김 | 암호는 로컬 요약만 저장 |
| 설정 | `⌘⇧S` | 단축키, 상태, 동기화, 보안 | 현재 입력기가 RIMES일 때만 열림 | — | Mailbox / Capsule 창을 안에 넣지 않음 |

실시간 번역, AI 생성, 의식의 흐름 입력은 버퍼 플러그인입니다. 병격은 내장 확장입니다. 버전과 ID는 아래 목록을 보십시오.

| 이름 | 종류 | 설명 | 기본 |
|---|---|---|---|
| 실시간 번역 | 버퍼 플러그인 | Apple 기기 내 번역. AI도 가능 | 사용. macOS 15+ |
| AI 생성 | 버퍼 플러그인 | Codex, Claude Code 또는 OpenAI 호환 API. Plain / Markdown / JSON. 결과는 Buffer에 남고 직접 확정 | 사용 |
| 의식의 흐름 입력 | 버퍼 플러그인 | 병음 또는 병격을 고른 AI에 넘겨, 서로 배타적인 추측을 최대 5개 | 사용. 고른 뒤에 전달 |
| 병격 | 내장 확장 | 동시에 누르기와 좌우를 나누어 누르기. 키 배열도 직접 정할 수 있음 | 끄기 |

## 기본 버퍼 플러그인

아래 표는 [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json)에서 생성됩니다. 플러그인을 갱신할 때는 버전도 바꾸고 `python3 scripts/sync-buffer-plugin-catalog.py --check`를 통과해야 합니다.

| 플러그인 | ID | 버전 | 기본 설치 | 기본 상태 |
|---|---|---:|---|---|
| ChatGPT | `builtin.codex-cli` | 1.1 | RIMES에 포함 | 사용 |
| Claude | `builtin.claude-code-cli` | 1.1 | RIMES에 포함 | 사용 |
| AI API | `builtin.openai-compatible` | 1.0 | RIMES에 포함 | 사용 |
| Reference | `builtin.scholay` | 0.1 | RIMES에 포함 | 사용 |
| Polisher | `builtin.polisher` | 0.1 | RIMES에 포함 | 사용 |
| LaTeX | `builtin.latex` | 0.1 | RIMES에 포함 | 사용 |
| 실시간 번역 | `builtin.apple-translation` | 2.2 | RIMES에 포함 | 사용 |
| 의식의 흐름 입력 | `builtin.stream-input` | 1.4 | RIMES에 포함 | 사용 |
| 전자 음악 | `builtin.music` | 0.2.3 | RIMES에 포함 | 사용 |
| 모스 부호 | `builtin.morse` | 0.1.0 | RIMES에 포함 | 사용 |

표의 플러그인은 모두 RIMES에 포함되며, 새로 설치하면 기본적으로 켜집니다.

## 내장 확장

| 확장 | 안정 ID | 버전 | 기본 상태 |
|---|---|---:|---|
| 통계 | `builtin.statistics` | 2.0 | 사용 |
| 타자 속도 | `builtin.typing-speed` | 2.0 | 사용 |
| 병격 | `builtin.fly-chord-learning` | 2.0 | 끄기 |

## 설치

공개 버전은 [macOS 1.1.1](https://github.com/scholay/rimes/releases/tag/v1.1.1), [Android 1.1.1](https://github.com/scholay/rimes/releases/tag/android-v1.1.1), [Windows 1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1), [iOS App Store 1.1.0](https://apps.apple.com/us/app/lingxi-ime/id6814620242)입니다. macOS 패키지는 서명 및 공증되었고 Android는 장기 서명 키를 사용하며 Windows EXE는 서명되지 않았습니다. iOS는 [TestFlight 공개 초대](https://testflight.apple.com/join/Kdj9RB4q)도 제공하며 설치 가능한 빌드는 TestFlight에서 확인할 수 있습니다. Linux는 현재 입력 스키마 데이터 미리보기를 공개합니다. 최신 소스와의 차이는 [패키지 점검 기록](validation/release-refresh-20261007.md)을 참고하세요. 소스를 받아 로컬에서 빌드할 수도 있습니다.

```bash
git clone --recurse-submodules https://github.com/scholay/rimes.git
cd rimes
```

| 플랫폼 | 진행 | 빌드 |
|---|---|---|
| macOS | 입력기, 그리고 Buffer, Capsule, Mailbox | `./build_install.sh` |
| iOS | 키보드와 본체 앱(iOS 17+). 오프라인 병음, 자연마, 오필, 영어, 그리고 Buffer | Xcode에서 [`platforms/ios/RIMES.xcodeproj`](platforms/ios/README.md)를 연다 |
| Windows | 네이티브 TSF 입력기, Buffer, 병격 및 공식 플러그인 설정; x64 / x86 | [`platforms/windows/native/README.md`](platforms/windows/native/README.md) 참고 |
| Android | 네이티브 InputConnection 키보드, Buffer, 공식 플러그인 6개 및 설정 가능한 AI 서비스 | [`platforms/android/README.md`](platforms/android/README.md) 참고 |
| Linux | Fcitx5 입력기, Buffer, Capsule. Mailbox는 아직 없다 | [`platforms/linux/ime/README.md`](platforms/linux/ime/README.md) 참고 |

## 문서

| 문서 | 내용 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 현재의 기준이 되는 전체 구조. 개발을 이어받을 때 먼저 읽는다 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2의 지난 계약과 겪은 문제 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | 플러그인의 선언적 설정 |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | 서명되지 않은 미리보기의 다운로드, 검증, 안전한 설치 |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux 입력 방안 미리보기의 범위와 검증 |
| [platforms/ios/README.md](platforms/ios/README.md) | iOS 키보드와 본체 앱 |
| [platforms/windows/native/README.md](platforms/windows/native/README.md) | Windows 네이티브 TSF 입력기 |
| [platforms/linux/ime/README.md](platforms/linux/ime/README.md) | Linux Fcitx5 입력기, Buffer, Capsule |
| [RELEASE.md](RELEASE.md) | 릴리스 절차. 채널, 명령 하나, 주기, 버전 규칙 |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | 릴리스 기술 참고. 서명, 설치기, 앱 안 업데이트, CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | 닫힌 릴리스 경로, 옛 저장소 이전, 이름 변경 기록 |
| [CHANGELOG.md](CHANGELOG.md) | 공개 GitHub Release와 커밋 메시지로 만든 버전별 변경 |

## 자동 업데이트

정식으로 서명되어 설치된 RIMES는 [`scholay/rimes`](https://github.com/scholay/rimes)의 GitHub Release를 확인합니다. 서명되지 않은 `vX.Y.Z-preview.N`은 이 경로에 들어가지 않습니다.

릴리스 입구는 하나이고, 버전 번호는 tag에서만 옵니다. 절차는 [RELEASE.md](RELEASE.md), 변경은 [CHANGELOG.md](CHANGELOG.md)를 보십시오.

```bash
./scripts/release.sh --dry-run preview  # 계획, CI 관문, 릴리스 노트를 미리 본다
./scripts/release.sh preview            # 서명되지 않은 macOS 미리보기 vX.Y.Z-preview.N
./scripts/release.sh stable             # 미리보기 선을 vX.Y.Z로 올린다 (Developer ID 필요)
./scripts/release.sh platform minor     # 유지보수용 Windows/Linux 데이터 미리보기 (macOS를 막지 않음)
```

모든 Release는 `scholay/rimes`에 올라갑니다. macOS `vX.Y.Z`는 정식판입니다. `vX.Y.Z-preview.N`은 서명되지 않은 Pre-release이며 자동 업데이트에 들어가지 않습니다. Windows/Linux `platform-preview-vX.Y.Z`는 항상 Pre-release입니다.

## 링크

- [RIME 입력기 엔진](https://rime.im/) — 이 프로젝트의 중국어 입력은 RIME을 기반으로 합니다.
- [Linux.do](https://linux.do/u/leowangling/preferences/account) — 진정성 있고 친절하며 단결되고 전문적인 커뮤니티 Linux.do와 그 구성원들에게 감사합니다.
- [iRime](https://github.com/jimmy54/iRime) — RIMES에 대한 안내와 소개에, iRime 작성자에게 감사합니다.

## 기여자

전체 명단은 [CONTRIBUTORS.md](CONTRIBUTORS.md)에 있습니다.

이 프로젝트의 핵심 유지관리자는 프로그래머 출신이 아닌, 일반 사용자를 위한 제품 매니저입니다. vibe coding 시대에 감사합니다.

**AI 프로그래밍 도우미**: Claude, Cursor, Codex, Grok이 설계, 구현, 검토에 참여했습니다.

## 알려진 문제

- **Linux: 배포가 끝나기 전에 Fcitx5를 끝내면 프로세스가 몇 분 동안 남을 수 있다.** 처음이거나 백그라운드의 librime 배포는 도중에 취소할 수 없고, 사전이 클수록 더 두드러집니다. [#43](https://github.com/scholay/rimes/issues/43)을 보십시오.
- **Linux: Buffer 도구 막대를 드래그한 직후 다른 입력칸을 누르면 캡처가 켜진 채로 남을 수 있다.** 지금은 X11의 Firefox에서만 재현됩니다. 손을 뗀 뒤 약 10밀리초 안에 같은 창의 다른 입력칸을 누를 때입니다. 한 번 더 누르거나 Esc로 돌아옵니다. [#44](https://github.com/scholay/rimes/issues/44)를 보십시오.

## 라이선스와 제3자

RIMES 자체 코드는 [Apache License 2.0](LICENSE)을 따릅니다. 적용 범위와 기존 MIT 허가는 [LICENSING.md](LICENSING.md)를 참고하십시오. 핵심 유지관리자는 [学术海](https://pm.scholay.com)입니다.

중국어 입력은 [Rime 입력 엔진(librime)](https://github.com/rime/librime)을 사용합니다. 출처 정보는 [NOTICE](NOTICE), 권장 표시 예시는 [ATTRIBUTION.md](ATTRIBUTION.md)에 있습니다. 표시 권고는 추가 라이선스 조건이 아닙니다.

제3자 구성 요소, 방안, 사전, Lua/OpenCC 데이터는 각자의 라이선스와 저작권 표시를 유지합니다. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [LICENSES](LICENSES/), `rime-data/licenses/`를 참고하십시오. 공식 무료 플러그인은 [rimes-plugins](https://github.com/scholay/rimes-plugins)에서 관리합니다.
