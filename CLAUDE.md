# CLAUDE.md

Shared foundation library for smkwlab Elixir CLI tools (registry-manager / thesis-monitor / ecosystem-manager). Provides mechanisms under the `ToolKit.*` namespace; consumers pin this library as a git dependency by semver tag.

## Design Rules

- **Pure library**: no supervision tree, no application callback. Keeps escript embedding trivial for consumers.
- **Mechanism here, policy in tools**: parsing/merging/rendering/I-O wrappers live here; command vocabularies, config schemas, and domain logic stay in each consumer tool.
- Consumers: `{:tool_kit, github: "smkwlab/elixir-tool-kit", tag: "vX.Y.Z"}` — never branch references. Tag a new semver release for every API addition.
- Elixir `~> 1.17` (matches the shared CI LTS lane). Runtime deps: jason / yaml_elixir / req only.

## Module Layout

- `ToolKit` — namespace root, `version/0`
- `ToolKit.CLI.*` — declarative command spec engine, parser, exit handling
- `ToolKit.Output.*` — East-Asian-width-aware text/table rendering, CSV helpers
- `ToolKit.Config.*` — layered config loading (defaults ⊕ YAML ⊕ env ⊕ CLI overrides)
- `ToolKit.GitHub.*` — Req-based REST client with injected token provider
- `ToolKit.Cache` — file cache with TTL and `get_or_fetch/3`

## Development Commands

```bash
mix deps.get
mix test                        # coverage floor: 80% (summary threshold)
mix format --check-formatted
mix credo
mix dialyzer
```

## Quality Gates

CI calls `smkwlab/.github/.github/workflows/elixir-ci.yml@v1` (LTS + latest Elixir lanes) plus the org AI code review workflow. All four checks above must pass; coverage below 80% fails the build.
