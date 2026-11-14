<h1 align="center">Lunlet</h1>

<p align="center">Codex と Claude Code を、Mac のノッチのそばに。</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <strong>日本語</strong>
</p>

<p align="center">
  <a href="https://github.com/yukunlabs/lunlet/releases/latest"><img src="https://img.shields.io/github/v/release/yukunlabs/lunlet?label=release" alt="最新リリース"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20on%20Apple%20silicon-lightgrey" alt="macOS 14 以降、Apple シリコン">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-0BSD-blue" alt="ライセンス：0BSD"></a>
</p>

<p align="center">
  <img src="docs/assets/screenshots/hero-overview.jpg" width="100%" alt="ノッチの下に開いた Lunlet のパネル。エージェントごとの惑星が上限の残りを示し、その下に日ごとのトークン使用量のグラフがある">
</p>

Lunlet はノッチの横に常駐し、コーディングエージェントが今なにをしているか、プランの上限があとどれだけ残っているかを表示します。Mac をロックして席を離れても、ターンが終わるたびにスマートフォンへ通知が届き、ひとこと返信すれば同じセッションが続きます。

手元の Mac の中だけで動作し、独自のサーバー、アナリティクス、テレメトリはありません。[1 分間の紹介動画を見る](https://yukunlabs.github.io/lunlet/#film)。

<sub>画像と紹介動画は、Lunlet 自身の画面を合成データで描画したものです。</sub>

## 機能

### セッション

<p align="center">
  <img src="docs/assets/screenshots/cue-island.jpg" width="100%" alt="ノッチの拡大図。ノッチを囲むアイランドに「Completed」、プロジェクト名、依頼内容が表示されている">
</p>

ローカルの Codex と Claude Code のセッションを、どのターミナルやエディタで動いていても 1 つの一覧にまとめ、直近のプロンプト、状態、トークン数を表示します。ターンの開始時と終了時には、ノッチに小さなアイランドが現れます。

### 上限と使用量

<p align="center">
  <img src="docs/assets/screenshots/panel-codex.jpg" width="49%" alt="Codex のページ。今週の残り、5 時間枠、クレジット、3 つのセッション">
  <img src="docs/assets/screenshots/panel-claude.jpg" width="49%" alt="Claude Code のページ。今週の残り、今日のトークン数、3 つのセッション">
</p>

各エージェントの週間上限は、ノッチの横に描かれます。パネルを開くと、Codex の 5 時間枠とクレジット、上限に達しそうな時期の見込み、日ごとのトークン使用量と API 価格での概算コストも確認できます。

### スマートフォンへの通知

<p align="center">
  <img src="docs/assets/screenshots/phone-feishu-notice.png" width="30%" alt="スマートフォンに表示された Feishu のカード。Codex の成功、依頼内容、エージェントの返答、返信欄がある">
  <img src="docs/assets/screenshots/phone-feishu-replied.png" width="30%" alt="返信を送った後の同じカード。状態は Sending">
  <img src="docs/assets/screenshots/phone-feishu-delivered.png" width="30%" alt="同じカード。状態は Delivered で、Codex が Mac 上で続きを実行している">
</p>

Mac がロックされている間、ターンが終わるたびに、あなた自身の Feishu（Lark）、Slack、Telegram のボットへ通知が届きます。スマートフォンから 1 回返信すると、同じセッションが続きます。実行の承認は Mac から離れません。設定方法は[メッセージング設定](docs/messaging.md)（英語）をご覧ください。

### そのほか

- ノッチのない Mac では、メニューバーの項目か、小さなデスクトップペットを使えます。
- Vine と Lantern のスキンは色を変えられ、[自作する](docs/skins.md)こともできます（英語）。

## インストール

1. [最新リリース](https://github.com/yukunlabs/lunlet/releases/latest)から `Lunlet-<version>-macos-arm64.dmg` をダウンロードして開き、Lunlet を「アプリケーション」にドラッグします。
2. Lunlet を開きます。現在は未署名のプレビュー版のため、初回のみ macOS で許可が必要です。macOS 15 以降では「完了」を選び、「システム設定 › プライバシーとセキュリティ」で「このまま開く」を選びます。macOS 14 では Lunlet を右クリックして「開く」を選びます。
3. ノッチの両脇にある「lun」と「let」にポインタを重ねるとパネルをプレビューでき、クリックすると開いたままになります。

macOS 14 以降を搭載した Apple シリコンの Mac と、この Mac でサインイン済みの Codex または Claude Code が必要です。アップデートは Lunlet の中から行えます。

## プライバシー

- Lunlet は手元の Mac で動作し、独自のサーバー、アナリティクス、テレメトリはありません。
- アクティビティと使用量を表示するために、Codex と Claude Code のローカルのセッション記録を読み取ります。Claude Code のログイン認証情報を読み取ることはありません。
- Claude Code を選択している間、Lunlet は Claude Code のユーザー設定にステータスラインと Stop フックを 1 つ追加します。Claude Code をオフにすると、フックは削除され、元のステータスラインに戻ります。
- 通知が送られるのは、Mac がロックされていて、ボットがペアリングされているときだけです。通知はそのメッセンジャーを経由してあなたの個人チャットに届き、プロジェクト、セッションのタイトル、依頼内容の短い抜粋、エージェントの最終的な返答が含まれます。
- ボットのトークンは Mac 上の、あなたのユーザーアカウントだけが読めるファイルに保存されます。

詳細は [docs/privacy.md](docs/privacy.md)（英語）をご覧ください。

## 現在の状況

Lunlet は初期段階の未署名プレビュー版です。まだ対応していないもの：スマートフォンからエージェントの質問に答えること、公証済みのダウンロード、Intel Mac、Linux、Codex と Claude Code 以外のエージェント。これまでに検証した内容は [docs/feasibility.md](docs/feasibility.md)（英語）に記録しています。

## ソースからビルド

```sh
scripts/build-app.sh --preview
open .tmp/Lunlet.app
```

Xcode Command Line Tools と Swift 6.2 以降が必要です。コントリビュートする場合は、まず [CONTRIBUTING.md](CONTRIBUTING.md)（英語）をお読みください。

## ドキュメント

- [メッセージング設定](docs/messaging.md)と[カスタムスキン](docs/skins.md)
- [プライバシー](docs/privacy.md)と[セキュリティポリシー](SECURITY.md)
- [要件](docs/requirements.md)、[実現性の検証](docs/feasibility.md)、[リリース](docs/releases.md)
- [製品ページ](https://yukunlabs.github.io/lunlet/)

これらのドキュメントは現在のところ英語のみです。

## ライセンス

[0BSD](LICENSE)。サードパーティの通知は [NOTICE.md](NOTICE.md) にあります。

Codex、Claude、Feishu、Lark、Slack、Telegram は各所有者の商標です。Lunlet は独立したプロジェクトであり、これらの企業と提携しておらず、承認も受けていません。
