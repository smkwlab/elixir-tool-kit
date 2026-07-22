defmodule ToolKit.Test.RegistryManagerSpecFixture do
  @moduledoc """
  registry-manager の CLI spec を再現したフィクスチャ。

  受け入れ基準「等価な spec を与えたとき registry-manager の現行 help 出力を
  バイト一致で再現する」の検証に使う。test/fixtures/registry_manager_help/ の
  期待値は registry-manager escript の実出力を採取したもの。
  """

  alias ToolKit.CLI.Spec

  @repo_types [
    "wr",
    "ise",
    "sotsuron",
    "master",
    "thesis",
    "latex",
    "poster",
    "sotsuron-report",
    "other"
  ]
  @output_formats ["table", "csv", "json"]
  @pr_states ["open", "closed", "all"]
  @pr_sort_keys ["repository", "updated", "created"]
  @list_sort_keys ["name", "time"]

  @option_catalog %{
    help: %{type: :boolean, alias: :h, values: nil, doc: "このヘルプを表示"},
    verbose: %{type: :boolean, alias: :v, values: nil, doc: "詳細ログを表示"},
    registry_repo: %{
      type: :string,
      alias: nil,
      values: nil,
      doc: "registry_repo を上書き（owner/repo 形式）"
    },
    config: %{type: :string, alias: :c, values: nil, doc: "設定ファイルのパスを上書き"},
    dry_run: %{type: :boolean, alias: :d, values: nil, doc: "実際の変更を行わない"},
    delete_github_repo: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "GitHubリポジトリ削除コマンドを案内"
    },
    force: %{type: :boolean, alias: :f, values: nil, doc: "確認をスキップ／既存設定を上書き"},
    org: %{type: :string, alias: nil, values: nil, doc: "対象の GitHub organization"},
    long: %{type: :boolean, alias: :l, values: nil, doc: "詳細テーブル表示"},
    show_type: %{type: :boolean, alias: nil, values: nil, doc: "リポジトリタイプ列を表示"},
    show_protection: %{type: :boolean, alias: :p, values: nil, doc: "保護状態列を表示"},
    no_names: %{type: :boolean, alias: nil, values: nil, doc: "学生名を非表示"},
    activity: %{type: :boolean, alias: :a, values: nil, doc: "リポジトリの最終活動時刻を表示"},
    owner_activity: %{type: :boolean, alias: :o, values: nil, doc: "オーナーの活動時刻を表示"},
    show_registry_updated: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "registry_updated_at 列を表示"
    },
    show_both_timestamps: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "リポジトリ/レジストリ両方の時刻列を表示"
    },
    no_cache: %{type: :boolean, alias: nil, values: nil, doc: "キャッシュを使用しない"},
    format: %{type: :string, alias: nil, values: @output_formats, doc: "出力形式"},
    type: %{type: :string, alias: :T, values: @repo_types, doc: "リポジトリタイプでフィルタ"},
    t: %{type: :boolean, alias: :t, values: nil, doc: "--sort time の短縮"},
    reverse: %{type: :boolean, alias: :r, values: nil, doc: "ソート順を反転"},
    show_student_id: %{type: :boolean, alias: :s, values: nil, doc: "学生IDを表示"},
    add_owner: %{type: :string, alias: nil, values: nil, doc: "オーナーを追加"},
    remove_owner: %{type: :string, alias: nil, values: nil, doc: "オーナーを削除"},
    set_owners: %{type: :string, alias: nil, values: nil, doc: "オーナーを設定（カンマ区切り）"},
    state: %{type: :string, alias: nil, values: @pr_states, doc: "PR 状態でフィルタ"},
    review_requested: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "レビューリクエスト保留中の PR のみ表示"
    },
    sort: %{type: :string, alias: nil, values: @pr_sort_keys, doc: "ソートキー"},
    all: %{type: :boolean, alias: nil, values: nil, doc: "全リポジトリを対象にする"},
    from_template: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "テンプレートから最新ワークフローを適用してから伝播"
    },
    graduated: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "名簿突合で卒業済み学生の登録リポジトリを一括対象にする"
    },
    list: %{type: :boolean, alias: nil, values: nil, doc: "候補一覧を判定理由つきで表示のみ（実行しない）"},
    interactive: %{
      type: :boolean,
      alias: :i,
      values: nil,
      doc: "候補を 1 件ずつ確認しながら archive（y/n/a/q）"
    },
    review_flow: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "review_flow を明示指定（--no-review-flow で false。省略時はタイプ由来の既定値）"
    }
  }

  @commands [
    %{
      name: "init",
      aliases: [],
      usage: ["init [owner/repo]"],
      summary:
        "レジストリデータリポジトリの bootstrap（private repo 作成・data/registry.json と README の初期投入・config 生成、冪等）",
      options: [:force],
      examples: ["init", "init smkwlab/thesis-student-registry --org smkwlab"]
    },
    %{
      name: "add",
      aliases: [],
      usage: [
        "add <repo_name> [--type <repo_type>]",
        "add <repo_name> <student_id> <repo_type>"
      ],
      summary: "リポジトリ情報を新規登録（1引数: 推論形式・推奨 / 3引数: 明示的形式）",
      options: [
        :dry_run,
        {:type, %{doc: "リポジトリタイプの推論を上書き（1引数形式のみ。名前に規則がない場合に使用）"}},
        :review_flow
      ],
      examples: [
        "add k21rs001-sotsuron",
        "add myorg/k21rs001-wr",
        "add k21rs001-jsai2026 --type other",
        "add k21rs001-fit26 --type latex --review-flow",
        "add k21rs001-sotsuron k21rs001 sotsuron"
      ]
    },
    %{
      name: "update",
      aliases: [],
      usage: ["update <repo_name> <field> <value>"],
      summary: "既存リポジトリ情報を更新",
      options: [:dry_run],
      examples: ["update k21rs001-fit26 review_flow true"]
    },
    %{
      name: "remove",
      aliases: ["rm"],
      usage: ["remove <repo_name>"],
      summary: "リポジトリ情報をレジストリから削除",
      options: [:dry_run, :delete_github_repo],
      examples: ["remove k21rs001-sotsuron", "remove k21rs001-sotsuron --delete-github-repo"]
    },
    %{
      name: "protect",
      aliases: [],
      usage: ["protect <repo_name>"],
      summary: "ブランチ保護設定完了をマーク",
      options: [:dry_run],
      examples: ["protect k21rs001-sotsuron"]
    },
    %{
      name: "list",
      aliases: ["ls"],
      usage: ["list [filter]"],
      summary: "リポジトリ一覧・状況を表示",
      options: [
        :long,
        :show_type,
        :show_protection,
        :no_names,
        :activity,
        :owner_activity,
        :show_registry_updated,
        :show_both_timestamps,
        :no_cache,
        :format,
        :type,
        {:sort, %{values: @list_sort_keys, doc: "ソートキー（デフォルト: name）"}},
        :t,
        :reverse,
        :show_student_id
      ],
      examples: [
        "list",
        "list --long",
        "list --type wr --long",
        "list --sort time -r",
        "list --format csv"
      ]
    },
    %{
      name: "validate",
      aliases: [],
      usage: ["validate [repo_name]"],
      summary: "データの整合性を検証（全件または単一リポジトリ）",
      options: [:format],
      examples: ["validate", "validate k21rs001-sotsuron", "validate --format json"]
    },
    %{
      name: "cache",
      aliases: ["cache-status", "cache-clear", "cache-refresh"],
      usage: ["cache [status|clear|refresh] [repo_name]"],
      summary: "キャッシュ管理（リポジトリ名指定でそのリポジトリのみ対象）",
      options: [:force],
      examples: ["cache status", "cache clear", "cache status k21rs001-sotsuron"]
    },
    %{
      name: "infer-student-id",
      aliases: [],
      usage: ["infer-student-id <repo_name>"],
      summary: "github_username から CSV を元に学生 ID を推論して設定",
      options: [:dry_run],
      examples: ["infer-student-id 91rs044-wr", "infer-student-id demouser-wr --dry-run"]
    },
    %{
      name: "edit",
      aliases: [],
      usage: ["edit <repo_name>"],
      summary: "リポジトリの GitHub オーナーを編集",
      options: [:add_owner, :remove_owner, :set_owners],
      examples: ["edit k21rs001-sotsuron --add-owner mentor-user"]
    },
    %{
      name: "pr-status",
      aliases: [],
      usage: ["pr-status [filter]"],
      summary: "各リポジトリの Pull Request 状態を表示",
      options: [:format, :type, :state, :review_requested, :sort, :reverse, :no_cache],
      examples: ["pr-status", "pr-status --review-requested", "pr-status --sort updated -r"]
    },
    %{
      name: "propagate-workflow",
      aliases: [],
      usage: ["propagate-workflow <repo_name>", "propagate-workflow --all [--type TYPE]"],
      summary: "ワークフロー更新をドラフトブランチ階層に伝播（main → 0th-draft → … の順でマージ）",
      options: [:all, :type, :from_template, :dry_run],
      examples: [
        "propagate-workflow k92rs001-sotsuron",
        "propagate-workflow --all --type thesis --dry-run"
      ]
    },
    %{
      name: "archive",
      aliases: [],
      usage: [
        "archive <repo_name>",
        "archive --graduated [--list | --dry-run | -i]"
      ],
      summary:
        "卒業済みリポジトリを archive（open PR クローズ → archive → archived_at 記録）。--graduated で名簿突合の一括、--list で候補一覧のみ、--dry-run で副作用なしのシミュレーション、-i で 1 件ずつ確認しながら実行",
      options: [:graduated, :list, :dry_run, :interactive],
      examples: [
        "archive k21rs001-sotsuron",
        "archive --graduated --list",
        "archive --graduated --dry-run",
        "archive --graduated",
        "archive --graduated -i"
      ]
    }
  ]

  @doc "registry-manager と等価な %ToolKit.CLI.Spec{} を返す"
  def spec do
    %Spec{
      tool_name: "registry-manager",
      tool_summary: "学生リポジトリレジストリ管理ツール",
      option_catalog: @option_catalog,
      global_option_names: [:help, :verbose, :registry_repo, :config, :org],
      commands: @commands
    }
  end
end
