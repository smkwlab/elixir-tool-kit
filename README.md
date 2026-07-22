# elixir-tool-kit

smkwlab の Elixir CLI ツール(registry-manager / thesis-monitor / ecosystem-manager)が共有する基盤ライブラリ。

CLI spec エンジン・設定レイヤ・キャッシュ・GitHub クライアント・出力レンダリングを `ToolKit.*` 名前空間で提供する。

## 利用方法

git 依存としてタグを固定して参照する:

```elixir
def deps do
  [
    {:tool_kit, github: "smkwlab/elixir-tool-kit", tag: "v0.1.0"}
  ]
end
```

- バージョンは semver でタグ付けする(`vX.Y.Z`)
- 利用側は採用 PR ごとに明示的にタグを上げる

## 設計方針

- **純ライブラリ**: supervision tree を持たず、escript への組み込みを単純に保つ
- **ポリシーはツール側**: 本ライブラリは機構(パース・マージ・描画・I/O ラッパ)を提供し、コマンド語彙・設定スキーマ・ドメインロジックは各ツールが持つ
- Elixir `~> 1.17`

## 開発

```bash
mix deps.get
mix test              # カバレッジ床値 80%
mix format --check-formatted
mix credo
mix dialyzer
```

## ライセンス

[MIT](LICENSE)
