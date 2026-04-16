# Config Refactor Implementation Plan — Shipped

> **Status:** Shipped in [PR #2271](https://github.com/bytedance/deer-flow/pull/2271). All tasks complete. This document is an implementation log; for the shipped architecture see [design doc](./2026-04-12-config-refactor-design.md).
>
> **Goal:** Eliminate global mutable state in the configuration system — frozen `AppConfig`, pure `from_file()`, process-global + ContextVar-override lifecycle, `Runtime[DeerFlowContext]` propagation.
>
> **Tech Stack:** Pydantic v2 (`frozen=True`, `model_copy`), Python `contextvars.ContextVar` + `Token`, LangGraph `Runtime` / `ToolRuntime`.
>
> **Issues:** [#2151](https://github.com/bytedance/deer-flow/issues/2151) (implementation), [#1811](https://github.com/bytedance/deer-flow/issues/1811) (RFC)

## Post-mortem — divergences from the original plan

The implementation diverged from the original task-by-task plan in three places. The rationale lives in the design doc §7; here is the commit trail.

| Divergence | Original plan | Shipped | Triggering commit |
|------------|--------------|---------|-------------------|
| Lifecycle storage | Single `ContextVar` in new `context.py`, raises `ConfigNotInitializedError` | 3-tier: `AppConfig._global` (process singleton) + `_override: ContextVar` + auto-load-with-warning fallback | `7a11e925` ("use process-global + ContextVar override"), refined in `4df595b0` |
| Module / API shape | Top-level `get_app_config()` / `init_app_config()` in `context.py` | Classmethods on `AppConfig` (`current`, `init`, `set_override`, `reset_override`); `DeerFlowContext` + `resolve_context` in `deer_flow_context.py` | Same commits + `9040e49e` (call-site migration) |
| Middleware access | `resolve_context(runtime)` in every middleware and tool | Typed middleware reads `runtime.context.xxx` directly; `resolve_context()` only in dict-legacy callers; defensive `try/except` wrappers removed | `a934a822` ("simplify runtime context access") |

**Core insight:** ContextVar alone could not propagate config changes across Gateway request boundaries; process-global fixed that. The override ContextVar was kept for test/multi-client isolation. Hard-fail on uninitialized access (`ConfigNotInitializedError`) was dropped in favor of warning + auto-load to preserve backward compatibility, and tests use an autouse fixture in `backend/tests/conftest.py` to avoid the auto-load path.

---

## File Structure (shipped)

### New files

| File | Responsibility |
|------|---------------|
| `deerflow/config/deer_flow_context.py` | `DeerFlowContext` frozen dataclass + `resolve_context()` helper |

The originally-planned `deerflow/config/context.py` was never created. Lifecycle (`init`, `current`, `set_override`, `reset_override`) is on `AppConfig` itself in `app_config.py`.

### Modified files (config layer)

| File | Change |
|------|--------|
| `deerflow/config/app_config.py` | `frozen=True`, purify `from_file()`, delete mtime/reload/reset/push/pop; add classmethods `init`/`current`/`set_override`/`reset_override` with `_global` ClassVar and `_override` ContextVar |
| `deerflow/config/memory_config.py` | `frozen=True`, delete all globals and loader functions |
| `deerflow/config/title_config.py` | Same pattern |
| `deerflow/config/summarization_config.py` | Same pattern |
| `deerflow/config/subagents_config.py` | Same pattern |
| `deerflow/config/guardrails_config.py` | Same pattern (also delete `reset_guardrails_config`) |
| `deerflow/config/tool_search_config.py` | Same pattern |
| `deerflow/config/checkpointer_config.py` | Same pattern |
| `deerflow/config/stream_bridge_config.py` | Same pattern |
| `deerflow/config/acp_config.py` | Same pattern |
| `deerflow/config/extensions_config.py` | `frozen=True`, delete globals (`_extensions_config`, `reload_extensions_config`, `reset_extensions_config`, `set_extensions_config`) |
| `deerflow/config/database_config.py` | `frozen=True` (added in `4df595b0` review round) |
| `deerflow/config/run_events_config.py` | `frozen=True` (same) |
| `deerflow/config/tracing_config.py` | `frozen=True`, unchanged exports |
| `deerflow/config/__init__.py` | Removed deleted getter exports; no new re-exports needed since API is now on `AppConfig` |

### Modified files (production consumers)

| File | Change |
|------|--------|
| `deerflow/agents/lead_agent/agent.py` | `get_summarization_config()` → `AppConfig.current().summarization` |
| `deerflow/agents/lead_agent/prompt.py` | `get_memory_config()` → `AppConfig.current().memory`; ACP agents derived from `AppConfig.current()` |
| `deerflow/agents/middlewares/memory_middleware.py` | Reads `runtime.context.app_config.memory` directly (typed `Runtime[DeerFlowContext]`) |
| `deerflow/agents/middlewares/title_middleware.py` | `after_model` / `aafter_model` read `runtime.context.app_config.title`; helpers take `TitleConfig` as required parameter |
| `deerflow/agents/middlewares/tool_error_handling_middleware.py` | `get_guardrails_config()` → `AppConfig.current().guardrails` |
| `deerflow/agents/middlewares/loop_detection_middleware.py` | Reads `runtime.context.thread_id` directly |
| `deerflow/agents/middlewares/thread_data_middleware.py` | Reads `runtime.context.thread_id` directly |
| `deerflow/agents/middlewares/uploads_middleware.py` | Reads `runtime.context.thread_id` directly |
| `deerflow/agents/memory/updater.py` / `queue.py` / `storage.py` | `get_memory_config()` → `AppConfig.current().memory` |
| `deerflow/runtime/checkpointer/provider.py` / `async_provider.py` | `get_checkpointer_config()` → `AppConfig.current().checkpointer` |
| `deerflow/runtime/store/provider.py` / `async_provider.py` | Same pattern |
| `deerflow/runtime/stream_bridge/async_provider.py` | `get_stream_bridge_config()` → `AppConfig.current().stream_bridge` |
| `deerflow/runtime/runs/worker.py` | Constructs `DeerFlowContext(app_config=AppConfig.current(), thread_id=thread_id)` and passes via `agent.astream(context=...)` |
| `deerflow/subagents/registry.py` | `get_subagents_app_config()` → `AppConfig.current().subagents` |
| `deerflow/sandbox/middleware.py` | Reads `runtime.context.thread_id`; removed `runtime.context["sandbox_id"]` read path |
| `deerflow/sandbox/tools.py` | Removed 3× `runtime.context["sandbox_id"] = ...` writes; state now flows through `runtime.state["sandbox"]`; sandbox-config access via `resolve_context(runtime).app_config.sandbox` where dict-context fallback may still apply |
| `deerflow/sandbox/local/local_sandbox_provider.py` / `sandbox_provider.py` / `security.py` | `get_app_config()` → `AppConfig.current()` |
| `deerflow/community/*/tools.py` (tavily, jina_ai, firecrawl, exa, ddg_search, image_search, infoquest, aio_sandbox) | `get_app_config()` → `AppConfig.current()` |
| `deerflow/skills/loader.py` / `manager.py` / `security_scanner.py` | Same pattern |
| `deerflow/tools/builtins/*.py` | Typed tools read `runtime.context.xxx`; `task_tool.py` uses `resolve_context()` for bash-subagent guard |
| `deerflow/tools/tools.py` / `skill_manage_tool.py` | ACP agents derived from `AppConfig.current()`; skill manage reads `runtime.context.thread_id` |
| `deerflow/models/factory.py` | `get_app_config()` → `AppConfig.current()` |
| `deerflow/utils/file_conversion.py` | Same |
| `deerflow/client.py` | `AppConfig.init(AppConfig.from_file(config_path))`; constructs `DeerFlowContext` at invoke time. Earlier iterations used `set_override()`; removed in `a934a822` |
| `app/gateway/app.py` | `AppConfig.init(AppConfig.from_file())` at startup |
| `app/gateway/deps.py` / `auth/reset_admin.py` | `get_app_config()` → `AppConfig.current()` |
| `app/gateway/routers/mcp.py` / `skills.py` | Construct new config + `AppConfig.init()` instead of `reload_extensions_config()` |
| `app/gateway/routers/memory.py` / `models.py` | `get_memory_config()` → `AppConfig.current().memory`, etc. |
| `app/channels/service.py` | `get_app_config()` → `AppConfig.current()` |
| `backend/CLAUDE.md` | Config Lifecycle + `DeerFlowContext` sections updated |

### Modified files (tests)

~100 test locations updated. Patterns:

- `@patch("...get_memory_config")` → `@patch.object(AppConfig, "current", ...)` returning a frozen `AppConfig` with the desired sub-config
- Tests that mutated `AppConfig` instances now construct fresh ones or use `model_copy(update={...})`
- `backend/tests/conftest.py` gained an autouse `_auto_app_config` fixture that sets `AppConfig._global` to a minimal config for every test

New test files:
- `backend/tests/test_config_frozen.py` — verifies every config model rejects mutation
- `backend/tests/test_deer_flow_context.py` — verifies `DeerFlowContext` construction, defaults, and `resolve_context()` for all three input shapes
- `backend/tests/test_app_config_reload.py` — verifies lifecycle: `init()` visibility across contexts, `set_override()` + `reset_override()` with `Token`, auto-load warning

---

## Task log

All tasks complete. Checkboxes below reflect the shipped state. For detailed step-by-step TDD sequence, see the commit history on `refactor/config-deerflow-context`.

### Task 1: Freeze all sub-config models

- [x] Write `test_config_frozen.py` parameterized over every config model
- [x] Add `model_config = ConfigDict(frozen=True)` (or `extra="allow", frozen=True`) to every model
- [x] Add frozen=True to `DatabaseConfig`, `RunEventsConfig` in review round (`4df595b0`)
- [x] Fix tests that mutated config objects — use `model_copy(update={...})` or fresh instances

### Task 2: Freeze `AppConfig`

- [x] Extend `test_config_frozen.py` with `test_app_config_is_frozen`
- [x] Change `AppConfig.model_config` to `ConfigDict(extra="allow", frozen=True)`

### Task 3: Purify `from_file()`

- [x] Write test verifying no `load_*_from_dict()` calls happen during `from_file()`
- [x] Remove all 8 `load_*_from_dict()` calls and their imports from `app_config.py`

### Task 4: Replace `app_config.py` lifecycle

**Diverged from original plan.** See post-mortem for rationale.

- [x] ~~Create `deerflow/config/context.py`~~ → Lifecycle added directly to `AppConfig` as classmethods
- [x] Add `_global: ClassVar[AppConfig | None]` for process-global storage (atomic pointer swap under GIL, no lock)
- [x] Add `_override: ClassVar[ContextVar[AppConfig]]` for per-context override
- [x] Implement `init()`, `current()`, `set_override()` (returns `Token`), `reset_override()`
- [x] `current()` priority order: override → global → auto-load-with-warning
- [x] Delete old lifecycle: `get_app_config`, `reload_app_config`, `reset_app_config`, `set_app_config`, `peek_current_app_config`, `push_current_app_config`, `pop_current_app_config`, `_load_and_cache_app_config`, mtime globals
- [x] Write `test_app_config_reload.py` covering init/override/reset/auto-load paths

Commits: `7a11e925` (initial process-global + override), `4df595b0` (harden: `Token` return, auto-load warning, doc `_global` lock-free rationale).

### Task 5: Migrate call sites to `AppConfig.current()`

- [x] ~100 `get_app_config()` / `get_memory_config()` / `get_title_config()` / ... call sites migrated to `AppConfig.current().xxx`
- [x] Tests that patched module-level getters migrated to `patch.object(AppConfig, "current", ...)`
- [x] Update `deerflow/config/__init__.py` — removed deleted getter exports

Commits: `9040e49e` (bulk migration), `82fdabd7` (deps.py + reset_admin.py follow-up), `6c0c2ecf` (test mocks update), `faec3bf9` (runtime-path migration).

### Task 6: Delete sub-config module globals (memory / title / summarization)

- [x] Delete `_memory_config`, `get_memory_config`, `set_memory_config`, `load_memory_config_from_dict` from `memory_config.py`
- [x] Delete analogous globals from `title_config.py`, `summarization_config.py`
- [x] Migrate 6 production consumers of `get_memory_config`, 1 of `get_title_config`, 1 of `get_summarization_config`
- [x] Fix tests that patched the deleted getters

### Task 7: Delete remaining sub-config module globals

- [x] `subagents_config.py` — delete globals; migrate `subagents/registry.py`
- [x] `guardrails_config.py` — delete globals + `reset_guardrails_config`; migrate `tool_error_handling_middleware.py`
- [x] `tool_search_config.py` — delete globals (no production consumers)
- [x] `checkpointer_config.py` — delete globals; migrate 2 consumers in runtime/
- [x] `stream_bridge_config.py` — delete globals; migrate 1 consumer
- [x] `acp_config.py` — delete globals; migrate 2 consumers (`agents/lead_agent/prompt.py`, `tools/tools.py`)
- [x] `extensions_config.py` — delete globals + `reload_extensions_config`/`reset_extensions_config`/`set_extensions_config`; migrate 4 consumers (`sandbox/tools.py`, `client.py`, `gateway/routers/mcp.py`, `gateway/routers/skills.py`)

### Task 8: Update `__init__.py` exports

- [x] Remove deleted-getter exports; keep type exports (`AppConfig`, `ExtensionsConfig`, `MemoryConfig`, etc.)
- [x] `tracing_config` re-exports preserved (still function-based, no lifecycle change)

### Task 9: Gateway config update flow

- [x] `app/gateway/routers/mcp.py`: write extensions_config.json → `AppConfig.init(AppConfig.from_file())`
- [x] `app/gateway/routers/skills.py`: same pattern
- [x] `deerflow/client.py`: `update_mcp_config()` and `update_skill()` reuse the same pattern (now via `AppConfig.current().extensions` + `init(AppConfig.from_file())`)

### Task 10: Create `DeerFlowContext`

- [x] Create `deerflow/config/deer_flow_context.py` with `DeerFlowContext` frozen dataclass
- [x] Fields: `app_config: AppConfig`, `thread_id: str`, `agent_name: str | None = None`
- [x] Typed via `TYPE_CHECKING` import to avoid circular dependency
- [x] Wire into `create_agent(context_schema=DeerFlowContext)` in `lead_agent/agent.py`
- [x] Wire into `DeerFlowClient.stream(context=...)`

### Task 11: Add `resolve_context()` helper

- [x] Handle typed context (Gateway/Client path): return `runtime.context` directly
- [x] Handle dict context (legacy/tests): construct `DeerFlowContext` from dict keys; warn on empty `thread_id`
- [x] Handle missing context (LangGraph Server): fall back to `get_config().get("configurable", {})`; warn on empty `thread_id`
- [x] Write `test_deer_flow_context.py` covering all three paths

### Task 12: Remove `sandbox_id` from `runtime.context`

- [x] Delete 3× `runtime.context["sandbox_id"] = sandbox_id` writes in `sandbox/tools.py`
- [x] Delete context-based release path in `sandbox/middleware.py:after_agent`
- [x] Sandbox state flows exclusively through `runtime.state["sandbox"] = {"sandbox_id": ...}`

### Task 13: Wire `DeerFlowContext` into Gateway runtime and client

- [x] `deerflow/runtime/runs/worker.py`: construct `DeerFlowContext(app_config=AppConfig.current(), thread_id=thread_id)`, pass via `agent.astream(context=...)`; remove dict-context injection
- [x] `deerflow/client.py`: call `AppConfig.init(AppConfig.from_file(config_path))` in `__init__` / `_reload_config()`; construct `DeerFlowContext` at invoke time

### Task 14: Migrate middleware/tools from dict access to typed access

Originally planned as "replace with `resolve_context()`". Shipped as: typed middleware reads `runtime.context.xxx` directly; `resolve_context()` only where dict-context may still appear.

- [x] `thread_data_middleware`, `uploads_middleware`, `memory_middleware`, `loop_detection_middleware`: `runtime.context.thread_id` direct read
- [x] `sandbox/middleware.py`: same
- [x] `present_file_tool`, `setup_agent_tool`, `skill_manage_tool`: same pattern (typed `ToolRuntime`)
- [x] `task_tool.py`: keep `resolve_context()` for bash-subagent guard (uses `app_config`)
- [x] `sandbox/tools.py`: keep `resolve_context()` for sandbox config + thread_id in dict-legacy paths

Commit: `a934a822`.

### Task 15: Middleware reads config from Runtime

- [x] `memory_middleware`: `runtime.context.app_config.memory` — no wrapper, no `try/except`
- [x] `title_middleware`: `runtime.context.app_config.title` passed as required parameter to helpers; no `TitleConfig | None` fallback
- [x] `tool_error_handling_middleware`: reads from `AppConfig.current().guardrails` (lives outside per-invocation context)

Commit: `a934a822`.

### Task 16: Final cleanup and verification

- [x] Grep verified: no remaining `runtime.context.get(...)` / `runtime.context[...]` patterns in production code (the pattern exists in `app/channels/wechat.py` but is unrelated — it's a channel-token helper, not LangGraph runtime)
- [x] Grep verified: no remaining `get_memory_config` / `get_title_config` / `get_summarization_config` / `get_subagents_app_config` / `get_guardrails_config` / `get_tool_search_config` / `get_checkpointer_config` / `get_stream_bridge_config` / `get_acp_agents` / `reload_*` / `reset_*` / `set_extensions_config` / `push_current_app_config` / `pop_current_app_config` / `load_*_from_dict` references
- [x] Full test suite passes (`make test` — 2376 passed per PR description)
- [x] CI green (backend-unit-tests)
- [x] `backend/CLAUDE.md` updated with new Config Lifecycle and `DeerFlowContext` sections

---

## Follow-ups (not in this PR)

None required for correctness. Optional enhancements tracked separately:

- Consider re-exporting `DeerFlowContext` / `resolve_context` from `deerflow.config.__init__` for ergonomic imports. Currently callers import from `deerflow.config.deer_flow_context` directly.
- The auto-load-with-warning fallback in `AppConfig.current()` is pragmatic but obscures the init call graph. Once all test fixtures use `conftest.py`'s `_auto_app_config` autouse, consider promoting the warning to an error behind a feature flag.
- `app/channels/wechat.py` uses `_resolve_context_token` — unrelated naming collision with `resolve_context()`. No action required but worth noting for future readers.
