-module(beam_agent_capability_contract_tests).

-include_lib("eunit/include/eunit.hrl").

all_registry_capabilities_have_contract_coverage_test() ->
    RegistryIds = ordsets:from_list(beam_agent_capabilities:capability_ids()),
    ProofIds = ordsets:from_list([maps:get(id, Spec) || Spec <- capability_specs()]),
    ?assertEqual(RegistryIds, ProofIds).

canonical_api_exports_exist_for_every_capability_test() ->
    lists:foreach(
        fun(#{apis := Apis}) ->
            lists:foreach(
                fun({Module, Function, Arity}) ->
                    ensure_module_loaded(Module),
                    ?assert(erlang:function_exported(Module, Function, Arity))
                end,
                Apis
            )
        end,
        capability_specs()
    ).

all_capability_backend_pairs_use_supported_truth_levels_test() ->
    ValidLevels = ordsets:from_list([missing, partial, baseline, full, in_progress]),
    Violations = [
        {maps:get(id, Capability), Backend, maps:get(support_level, SupportInfo)}
        || Capability <- beam_agent_capabilities:all(),
           {Backend, SupportInfo} <- maps:to_list(maps:get(support, Capability)),
           not ordsets:is_element(maps:get(support_level, SupportInfo), ValidLevels)
    ],
    ?assertEqual([], Violations).

ensure_module_loaded(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> ok;
        {error, Reason} -> ?assertEqual({module, Module}, {error, Reason})
    end.

capability_specs() ->
    [
        #{
            id => session_lifecycle,
            apis => [{beam_agent, start_session, 1},
                     {beam_agent, query, 2},
                     {beam_agent, query, 3},
                     {beam_agent, stop, 1}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "beam_agent_ex/test/canonical/beam_agent_test.exs",
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/codex/codex_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl"
            ]
        },
        #{
            id => session_info,
            apis => [{beam_agent, session_info, 1}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "beam_agent_ex/test/wrappers/claude_ex_test.exs",
                "beam_agent_ex/test/wrappers/codex_ex_test.exs",
                "beam_agent_ex/test/wrappers/gemini_ex_test.exs",
                "beam_agent_ex/test/wrappers/opencode_ex_test.exs",
                "beam_agent_ex/test/wrappers/copilot_ex_test.exs"
            ]
        },
        #{
            id => runtime_model_switch,
            apis => [{beam_agent, set_model, 2}],
            proof_files => [
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/codex/codex_exec_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl"
            ]
        },
        #{
            id => interrupt,
            apis => [{beam_agent, interrupt, 1}, {beam_agent, abort, 1}],
            proof_files => [
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/codex/codex_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl"
            ]
        },
        #{
            id => permission_mode,
            apis => [{beam_agent, set_permission_mode, 2}],
            proof_files => [
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl",
                "test/public/beam_agent_fallback_tests.erl",
                "test/core/beam_agent_runtime_core_tests.erl"
            ]
        },
        #{
            id => session_history,
            apis => [{beam_agent, list_sessions, 0},
                     {beam_agent, list_sessions, 1},
                     {beam_agent, get_session_messages, 1},
                     {beam_agent, get_session_messages, 2},
                     {beam_agent, get_session, 1}],
            proof_files => [
                "test/core/beam_agent_session_store_core_tests.erl",
                "test/backends/claude/claude_session_store_tests.erl",
                "test/public/beam_agent_tests.erl"
            ]
        },
        #{
            id => session_mutation,
            apis => [{beam_agent, fork_session, 2},
                     {beam_agent, revert_session, 2},
                     {beam_agent, unrevert_session, 1},
                     {beam_agent, share_session, 1},
                     {beam_agent, share_session, 2},
                     {beam_agent, unshare_session, 1},
                     {beam_agent, summarize_session, 1},
                     {beam_agent, summarize_session, 2}],
            proof_files => [
                "test/core/beam_agent_session_store_core_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl"
            ]
        },
        #{
            id => thread_management,
            apis => [{beam_agent, thread_start, 2},
                     {beam_agent, thread_resume, 2},
                     {beam_agent, thread_resume, 3},
                     {beam_agent, thread_list, 1},
                     {beam_agent, thread_list, 2},
                     {beam_agent, thread_fork, 2},
                     {beam_agent, thread_fork, 3},
                     {beam_agent, thread_read, 2},
                     {beam_agent, thread_read, 3},
                     {beam_agent, thread_archive, 2},
                     {beam_agent, thread_unarchive, 2},
                     {beam_agent, thread_rollback, 3},
                     {beam_agent, thread_loaded_list, 1},
                     {beam_agent, thread_loaded_list, 2},
                     {beam_agent, thread_compact, 2}],
            proof_files => [
                "test/core/beam_agent_threads_core_tests.erl",
                "test/public/beam_agent_fallback_tests.erl",
                "test/backends/codex/codex_realtime_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl"
            ]
        },
        #{
            id => metadata_accessors,
            apis => [{beam_agent, capabilities, 0},
                     {beam_agent, capabilities, 1},
                     {beam_agent, supports, 2}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "beam_agent_ex/test/canonical/beam_agent_test.exs"
            ]
        },
        #{
            id => in_process_mcp,
            apis => [{beam_agent, mcp_status, 1},
                     {beam_agent, mcp_server_reload, 1}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "test/core/beam_agent_behaviour_tests.erl"
            ]
        },
        #{
            id => mcp_management,
            apis => [{beam_agent, mcp_server_status, 1},
                     {beam_agent, mcp_server_oauth_login, 2},
                     {beam_agent, set_mcp_servers, 2},
                     {beam_agent, reconnect_mcp_server, 2},
                     {beam_agent, toggle_mcp_server, 3}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl"
            ]
        },
        #{
            id => hooks,
            apis => [{beam_agent, start_session, 1}],
            proof_files => [
                "test/core/beam_agent_hooks_core_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl"
            ]
        },
        #{
            id => checkpointing,
            apis => [{beam_agent, rewind_files, 2}],
            proof_files => [
                "test/core/beam_agent_checkpoint_core_tests.erl",
                "test/public/beam_agent_tests.erl"
            ]
        },
        #{
            id => thinking_budget,
            apis => [{beam_agent, set_max_thinking_tokens, 2}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "test/core/beam_agent_runtime_core_tests.erl"
            ]
        },
        #{
            id => task_stop,
            apis => [{beam_agent, stop_task, 2}],
            proof_files => [
                "test/public/beam_agent_tests.erl",
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl"
            ]
        },
        #{
            id => command_execution,
            apis => [{beam_agent, command_run, 2},
                     {beam_agent, command_run, 3},
                     {beam_agent, command_write_stdin, 3},
                     {beam_agent, command_write_stdin, 4},
                     {beam_agent, send_command, 3},
                     {beam_agent, turn_respond, 3}],
            proof_files => [
                "test/backends/codex/codex_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl",
                "beam_agent_ex/test/wrappers/codex_ex_test.exs",
                "beam_agent_ex/test/wrappers/opencode_ex_test.exs",
                "beam_agent_ex/test/wrappers/copilot_ex_test.exs",
                "beam_agent_ex/test/wrappers/gemini_ex_test.exs"
            ]
        },
        #{
            id => approval_callbacks,
            apis => [{beam_agent, turn_respond, 3}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "test/backends/claude/claude_agent_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl",
                "test/backends/copilot/copilot_session_tests.erl"
            ]
        },
        #{
            id => user_input_callbacks,
            apis => [{beam_agent, send_command, 3}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "beam_agent_ex/test/wrappers/claude_ex_test.exs",
                "beam_agent_ex/test/wrappers/gemini_ex_test.exs",
                "beam_agent_ex/test/wrappers/opencode_ex_test.exs"
            ]
        },
        #{
            id => realtime_review,
            apis => [{beam_agent, review_start, 2},
                     {beam_agent, collaboration_mode_list, 1},
                     {beam_agent, experimental_feature_list, 1},
                     {beam_agent, experimental_feature_list, 2},
                     {beam_agent, thread_realtime_start, 2},
                     {beam_agent, thread_realtime_append_audio, 3},
                     {beam_agent, thread_realtime_append_text, 3},
                     {beam_agent, thread_realtime_stop, 2}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "test/backends/codex/codex_realtime_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/public/beam_agent_tests.erl"
            ]
        },
        #{
            id => config_management,
            apis => [{beam_agent, config_read, 1},
                     {beam_agent, config_read, 2},
                     {beam_agent, config_update, 2},
                     {beam_agent, config_providers, 1},
                     {beam_agent, config_value_write, 3},
                     {beam_agent, config_value_write, 4},
                     {beam_agent, config_batch_write, 2},
                     {beam_agent, config_batch_write, 3},
                     {beam_agent, config_requirements_read, 1},
                     {beam_agent, external_agent_config_detect, 1},
                     {beam_agent, external_agent_config_detect, 2},
                     {beam_agent, external_agent_config_import, 2}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "test/core/beam_agent_runtime_core_tests.erl",
                "test/public/beam_agent_tests.erl"
            ]
        },
        #{
            id => provider_management,
            apis => [{beam_agent, provider_list, 1},
                     {beam_agent, current_provider, 1},
                     {beam_agent, set_provider, 2},
                     {beam_agent, provider_auth_methods, 1},
                     {beam_agent, provider_oauth_authorize, 3},
                     {beam_agent, provider_oauth_callback, 3}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "test/core/beam_agent_runtime_core_tests.erl",
                "test/public/beam_agent_tests.erl"
            ]
        },
        #{
            id => attachments,
            apis => [{beam_agent, query, 3}],
            proof_files => [
                "test/core/beam_agent_attachments_tests.erl",
                "test/public/beam_agent_fallback_tests.erl",
                "test/backends/copilot/copilot_protocol_tests.erl"
            ]
        },
        #{
            id => event_streaming,
            apis => [{beam_agent, event_subscribe, 1},
                     {beam_agent, receive_event, 2},
                     {beam_agent, receive_event, 3},
                     {beam_agent, event_unsubscribe, 2}],
            proof_files => [
                "test/public/beam_agent_fallback_tests.erl",
                "test/backends/codex/codex_realtime_session_tests.erl",
                "test/backends/opencode/opencode_session_tests.erl",
                "test/backends/gemini/gemini_cli_session_tests.erl"
            ]
        }
    ].

