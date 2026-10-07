# RIMES

[![中文](.github/readme/labels/zh.svg)](README.md) [![English](.github/readme/labels/en.svg)](README.en.md) [![日本語](.github/readme/labels/ja.svg)](README.ja.md) [![한국어](.github/readme/labels/ko.svg)](README.ko.md) [![Español](.github/readme/labels/es.svg)](README.es.md)

オープンソースの精神に敬意を表します。本プロジェクトの中国語入力ロジックは [RIME 入力メソッドエンジン](https://rime.im/) に基づいています。
複数のオペレーティングシステムに対応する入力メソッドです。個人の使い方を受け止める、三つの独自のスロットがあります。1. 確定前の明示的なバッファ（Buffer） 2. クリップボード履歴、スクリーンショット、個人の知識ベースを扱う記憶カプセル（Capsule） 3. 外部からの情報を受け取る会話ウィンドウ（Mailbox）。

全拼、双拼、声筆、五筆、英語の方案に対応し、速記で使う並打入力と、カスタム方案の読み込みにも対応します。はじめて使う人向けに、インストールパッケージは librime と辞書を**同梱**し、すぐ使えます。

> **RIMES** は本プロジェクトのアーキテクチャ名です。公開上の製品名は、英語では **Lingxi IME**、簡体字中国語では **灵犀输入法**、繁体字中国語では **靈犀輸入法** です。iOS App Store ではすでにこれらの製品名を使用しています。

## デモ動画

- [Bilibili · 全体紹介](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin · 製品デモ](https://www.douyin.com/video/7671078195197742355)

## 何を解決するか

一つの入力メソッドで、翻訳、生成、推敲といった日常の作業を、今開いているアプリを離れずに済ませます。入力メソッドとプラグインが担います。

- **Buffer**（`⌘⇧B`）：確定前のテキスト作業台。中国語も英語も、まずバッファに入ります。リアルタイム翻訳や、選んだ AI コネクタによる生成と書き直しができます。確認したあと、現在の入力欄へ**明示的に送ります**。
- **Capsule**（`⌘⇧V`）：画面下端のバー。コピーした直後のテキスト、リンク、画像、ファイル、色は「最近」に出ます。残しておきたいものは、ノート、画像、PDF、スキル、パスワードに収めます。
- **Mailbox**（`⌘⇧M`）：AI の会話、メモ、確認待ちの外部プッシュは、このウィンドウに残ります。新しい会話を始め、設定済みのコネクタを選べます。

## 主な機能について

> インストール後、グラフィカルログインに入ると、一度きりのバックグラウンド処理が `open -g` で同じ RIMES プロセスを起動します。そのため Buffer、Clipboard History、Mailbox、Capsule のグローバルショートカットは、どの入力メソッドからでも使えます。
>
> リリースパッケージはシステム payload を置き換える前に、この Mac の通常アカウントをすべて監査します。postinstall が退役させられる現在の GUI ユーザーの開発版を除き、同じ ID の開発版アプリやジョブが見つかった場合、または home を安全に確認できない場合は、すぐに失敗します。postinstall が開発版を退役させ、もう一度監査したあとで、ロールバックできるトランザクションとしてシステムジョブを更新します。ログイン guard は、その後に現れた開発版の痕跡を防御的に止めるだけです。どちらのジョブも `KeepAlive` を設定せず、二つ目の UI/IME サービスも起動しません。
>
> Mailbox と Capsule は、キーボードフォーカスを普通に取る管理ウィンドウです。ほかの入力メソッドからショートカット（または Mailbox の通知）で開くとき、RIMES は先に自分を現在の入力メソッドへ切り替えてから開きます。閉じても元には戻さず、その後自分でほかの入力メソッドへ切り替えても、その選択は取り消されません。そのときは下記のとおり機能が制限されます。
>
> これらの機能は、ほかの入力メソッドの IMK クライアントに触れず、その未確定文字列を読んだり、確定したり、取り消したりしません。注入するキーは、Capsule を有効化したときの任意の `⌘V` 一回だけです（下記の Capsule バーを参照）。設定のショートカットも入力メソッドをまたいで使えます。Mailbox と Capsule のページは設定と状態だけを示し、実際の会話と内容はそれぞれのウィンドウに残します。

| 機能 | ショートカット | 内容 | 操作 | 保存 | 境界 |
|---|---|---|---|---|---|
| 入力方案 | — | 霧凇全拼、自然碼、小鶴、五筆 86、英語 | — | — | — |
| バッファ | `⌘⇧B` | 確定前のテキスト | 先に RIMES へ切り替え、取り込んで分割して送る | — | ほかへ切り替えたあとはシステムクリップボードのみ。IMK は使わない |
| Capsule バー | `⌘⇧V` | 直前のコピー。ノート、画像、PDF、スキル、パスワード | クリックで選択、ダブルクリックまたは Return で貼り付け。`⌘S` で保存 | この Mac のみ | 貼り付けにはアクセシビリティが必要。未許可ならクリップボードへ入れるだけ |
| Mailbox | `⌘⇧M` | AI の会話、メモ、確認待ちのプッシュ | 新しい会話。最初の Return で生成を始める | モデルはその会話だけに結び付く | CLI はそれぞれの既定モデル |
| Capsule 管理 | 歯車または筆 | 五種類の項目。プレビューとコピー | 四組の並打のあとパスワードを表示。最長 15 秒 | iCloud は任意。パスワードと鍵はこの Mac に残す | 合言葉はローカルのダイジェストだけを保存 |
| 設定 | `⌘⇧S` | ショートカット、状態、同期、セキュリティ | 現在の入力メソッドが RIMES のときだけ開く | — | Mailbox / Capsule のウィンドウは埋め込まない |

リアルタイム翻訳、AI 生成、意識の流れ入力はバッファプラグインです。並打は組み込み拡張です。バージョンと ID は下の一覧を見てください。

| 名前 | 種類 | 説明 | 既定 |
|---|---|---|---|
| リアルタイム翻訳 | バッファプラグイン | Apple のオンデバイス翻訳。AI も使える | 有効。macOS 15+ |
| AI 生成 | バッファプラグイン | Codex、Claude Code、または OpenAI 互換 API。Plain / Markdown / JSON。結果は Buffer に残り、自分で確定する | 有効 |
| 意識の流れ入力 | バッファプラグイン | 拼音または並打を選んだ AI に渡し、互いに排他的な候補を最大 5 つ返す | 有効。選んでから送る |
| 並打 | 組み込み拡張 | 同時押しと左右分け打ち。キー配列はカスタムできる | 無効 |

## 同梱のバッファプラグイン

下の表は [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json) から生成されています。プラグインを更新するときはバージョンも更新し、`python3 scripts/sync-buffer-plugin-catalog.py --check` を通してください。

| プラグイン | ID | バージョン | 既定の導入 | 既定の状態 |
|---|---|---:|---|---|
| ChatGPT | `builtin.codex-cli` | 1.1 | RIMES に同梱 | 有効 |
| Claude | `builtin.claude-code-cli` | 1.1 | RIMES に同梱 | 有効 |
| AI API | `builtin.openai-compatible` | 1.0 | RIMES に同梱 | 有効 |
| Reference | `builtin.scholay` | 0.1 | RIMES に同梱 | 有効 |
| Polisher | `builtin.polisher` | 0.1 | RIMES に同梱 | 有効 |
| LaTeX | `builtin.latex` | 0.1 | RIMES に同梱 | 有効 |
| リアルタイム翻訳 | `builtin.apple-translation` | 2.2 | RIMES に同梱 | 有効 |
| 意識の流れ入力 | `builtin.stream-input` | 1.4 | RIMES に同梱 | 有効 |
| 電子音楽 | `builtin.music` | 0.2.3 | RIMES に同梱 | 有効 |
| モールス符号 | `builtin.morse` | 0.1.0 | RIMES に同梱 | 有効 |

表のプラグインはすべて RIMES に同梱され、新規インストール後は既定で有効です。

## 組み込み拡張

| 拡張 | 安定 ID | バージョン | 既定の状態 |
|---|---|---:|---|
| 統計 | `builtin.statistics` | 2.0 | 有効 |
| タイピング速度 | `builtin.typing-speed` | 2.0 | 有効 |
| 並打 | `builtin.fly-chord-learning` | 2.0 | 無効 |

## インストール

公開版は [macOS 1.1.1](https://github.com/scholay/rimes/releases/tag/v1.1.1)、[Android 1.1.1](https://github.com/scholay/rimes/releases/tag/android-v1.1.1)、[Windows 1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1)、[iOS App Store 1.1.0](https://apps.apple.com/us/app/lingxi-ime/id6814620242) です。macOS は署名・公証済み、Android は長期署名鍵を使用し、Windows EXE は未署名です。iOS は [TestFlight 公開招待](https://testflight.apple.com/join/Kdj9RB4q)も提供し、インストール可能なビルドは TestFlight に表示されます。Linux は現在、入力スキームのデータプレビューを公開しています。最新ソースとの差分は[パッケージ監査](validation/release-refresh-20261007.md)を参照してください。ソースからローカルビルドも可能です。

```bash
git clone --recurse-submodules https://github.com/scholay/rimes.git
cd rimes
```

| プラットフォーム | 進捗 | ビルド |
|---|---|---|
| macOS | 入力メソッドに加え、Buffer、Capsule、Mailbox | `./build_install.sh` |
| iOS | キーボードと本体アプリ（iOS 17+）。オフラインの拼音、自然碼、五筆、英語、および Buffer | Xcode で [`platforms/ios/RIMES.xcodeproj`](platforms/ios/README.md) を開く |
| Windows | ネイティブ TSF 入力メソッド、Buffer、並打、公式プラグイン設定。x64 / x86 対応 | [`platforms/windows/native/README.md`](platforms/windows/native/README.md) を参照 |
| Android | ネイティブ InputConnection キーボード、Buffer、6つの公式プラグイン、設定可能な AI サービス | [`platforms/android/README.md`](platforms/android/README.md) を参照 |
| Linux | Fcitx5 入力メソッド、Buffer、Capsule。Mailbox はまだない | [`platforms/linux/ime/README.md`](platforms/linux/ime/README.md) を参照 |

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 現在の権威ある全体アーキテクチャ。開発を引き継ぐときは先に読む |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 の歴史的な契約と落とし穴 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | プラグインの宣言的な設定 |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | 未署名プレビューのダウンロード、検証、安全なインストール |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux の入力方案プレビューの範囲と検証 |
| [platforms/ios/README.md](platforms/ios/README.md) | iOS のキーボードと本体アプリ |
| [platforms/windows/native/README.md](platforms/windows/native/README.md) | Windows ネイティブ TSF 入力メソッド |
| [platforms/linux/ime/README.md](platforms/linux/ime/README.md) | Linux Fcitx5 入力メソッド、Buffer、Capsule |
| [RELEASE.md](RELEASE.md) | リリース手順。チャネル、一つのコマンド、ペース、バージョン規則 |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | リリースの技術資料。署名、インストーラ、アプリ内更新、CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | 閉じたリリース経路、旧リポジトリの移行、改名の記録 |
| [CHANGELOG.md](CHANGELOG.md) | 公開 GitHub Release とコミットメッセージから生成した版ごとの変更 |

## 自動更新

正式に署名してインストールした RIMES は、[`scholay/rimes`](https://github.com/scholay/rimes) の GitHub Release を確認します。未署名の `vX.Y.Z-preview.N` はこの経路に入りません。

リリースの入口は一つで、バージョン番号は tag だけから来ます。手順は [RELEASE.md](RELEASE.md)、変更は [CHANGELOG.md](CHANGELOG.md) を見てください。

```bash
./scripts/release.sh --dry-run preview  # 計画、CI の門、リリースノートをプレビュー
./scripts/release.sh preview            # 未署名の macOS プレビュー vX.Y.Z-preview.N
./scripts/release.sh stable             # プレビュー系列を vX.Y.Z にする（Developer ID が必要）
./scripts/release.sh platform minor     # 保守用の Windows/Linux データプレビュー（macOS を止めない）
```

すべての Release は `scholay/rimes` に公開されます。macOS の `vX.Y.Z` は正式版です。`vX.Y.Z-preview.N` は未署名の Pre-release で、自動更新には入りません。Windows/Linux の `platform-preview-vX.Y.Z` は常に Pre-release です。

## リンク

- [RIME 入力メソッドエンジン](https://rime.im/) — 本プロジェクトの中国語入力は RIME に基づいています。
- [Linux.do](https://linux.do/u/leowangling/preferences/account) — 誠実で、友好的で、結束し、専門的なコミュニティ Linux.do と、その仲間たちに感謝します。
- [iRime](https://github.com/jimmy54/iRime) — RIMES への指導と紹介に、iRime の作者へ感謝します。

## 貢献者

一覧は [CONTRIBUTORS.md](CONTRIBUTORS.md) にあります。

本プロジェクトの中心的なメンテナーは、プログラマー出身ではない、一般利用者向けのプロダクトマネージャーです。vibe coding の時代に感謝しています。

**AI プログラミング支援**：Claude、Cursor、Codex、Grok が設計、実装、レビューに加わりました。

## 既知の問題

- **Linux：デプロイが終わる前に Fcitx5 を終了すると、プロセスが数分残ることがある。** 初回またはバックグラウンドの librime デプロイは途中で取り消せません。辞書が大きいほど顕著です。[#43](https://github.com/scholay/rimes/issues/43) を参照。
- **Linux：Buffer のツールバーをドラッグした直後に別の入力欄をクリックすると、キャプチャが開いたままになることがある。** 今のところ X11 の Firefox だけで再現します。離してから約 10 ミリ秒以内に、同じウィンドウの別の入力欄を押した場合です。もう一度クリックするか Esc で戻ります。[#44](https://github.com/scholay/rimes/issues/44) を参照。

## ライセンスと第三者

RIMES 自身のコードは [Apache License 2.0](LICENSE) を採用しています。適用範囲と従来の MIT 許諾については [LICENSING.md](LICENSING.md) を参照してください。コアメンテナーは[学术海](https://pm.scholay.com)です。

中国語入力には [Rime 入力エンジン（librime）](https://github.com/rime/librime)を使用しています。[NOTICE](NOTICE) に帰属情報、[ATTRIBUTION.md](ATTRIBUTION.md) に任意の表示例を記載しています。表示の推奨は追加のライセンス条件ではありません。

第三者のコンポーネント、方案、辞書、Lua/OpenCC データはそれぞれのライセンスとクレジットを保ちます。[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[LICENSES](LICENSES/)、`rime-data/licenses/` を参照してください。公式の無料プラグインは [rimes-plugins](https://github.com/scholay/rimes-plugins) で管理します。
