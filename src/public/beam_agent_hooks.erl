-module(beam_agent_hooks).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for SDK lifecycle hooks inside `beam_agent`.".

-export([
    hook/2,
    hook/3,
    new_registry/0,
    register_hook/2,
    register_hooks/2,
    fire/3,
    build_registry/1
]).

-export_type([
    hook_event/0,
    hook_callback/0,
    hook_context/0,
    hook_matcher/0,
    hook_def/0,
    hook_registry/0
]).

-type hook_event() :: beam_agent_hooks_core:hook_event().
-type hook_callback() :: beam_agent_hooks_core:hook_callback().
-type hook_context() :: beam_agent_hooks_core:hook_context().
-type hook_matcher() :: beam_agent_hooks_core:hook_matcher().
-type hook_def() :: beam_agent_hooks_core:hook_def().
-type hook_registry() :: beam_agent_hooks_core:hook_registry().

hook(Event, Callback) -> beam_agent_hooks_core:hook(Event, Callback).
hook(Event, Callback, Matcher) -> beam_agent_hooks_core:hook(Event, Callback, Matcher).
new_registry() -> beam_agent_hooks_core:new_registry().
register_hook(Hook, Registry) -> beam_agent_hooks_core:register_hook(Hook, Registry).
register_hooks(Hooks, Registry) -> beam_agent_hooks_core:register_hooks(Hooks, Registry).
fire(Event, Ctx, Registry) -> beam_agent_hooks_core:fire(Event, Ctx, Registry).
build_registry(Opts) -> beam_agent_hooks_core:build_registry(Opts).
