-module(beam_agent_attachments_tests).

-include_lib("eunit/include/eunit.hrl").

prepare_materializes_non_native_attachments_test() ->
    SessionId = <<"attachments-gemini">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => gemini
    }),
    TmpFile = temp_path(<<"demo.txt">>),
    ok = file:write_file(binary_to_list(TmpFile), <<"demo file">>),
    Params = #{
        attachments => [
            #{type => file, path => TmpFile},
            #{type => text, text => <<"inline note">>}
        ]
    },
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Explain">>, Params),
    ?assertEqual(<<"Explain">>, Prompt),
    ?assertEqual(error, maps:find(attachments, Prepared)),
    AttachmentBlocks = maps:get(beam_agent_attachment_blocks, Prepared),
    ?assertMatch([#{type := file} | _], AttachmentBlocks),
    Manifest = maps:get(beam_agent_attachment_manifest, Prepared),
    ?assertMatch([#{type := file} | _], Manifest),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    ?assertMatch([#{<<"type">> := <<"text">>, <<"text">> := <<"Explain">>} | _], PromptBlocks),
    ?assert(lists:any(fun
        (#{<<"type">> := <<"resource">>}) -> true;
        (_) -> false
    end, PromptBlocks)),
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := <<"inline note">>}) -> true;
        (_) -> false
    end, PromptBlocks)),
    ok = file:delete(binary_to_list(TmpFile)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

prepare_keeps_native_attachment_payloads_test() ->
    SessionId = <<"attachments-codex">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => codex
    }),
    Params = #{attachments => [#{type => file, path => <<"/tmp/demo.txt">>}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Explain">>, Params),
    ?assertEqual(<<"Explain">>, Prompt),
    ?assertEqual({ok, [#{type => file, path => <<"/tmp/demo.txt">>}]} ,
        maps:find(attachments, Prepared)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

prepare_fallback_backend_keeps_structured_manifest_test() ->
    SessionId = <<"attachments-claude">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => mention, name => <<"repo">>, path => <<"app://repo">>}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Explain">>, Params),
    ?assertMatch(<<"Explain", _/binary>>, Prompt),
    ?assertEqual(error, maps:find(attachments, Prepared)),
    ?assertMatch([#{type := mention, mention := <<"repo">>}],
        maps:get(beam_agent_attachment_blocks, Prepared)),
    ?assertMatch([#{type := mention, mention := <<"repo">>}],
        maps:get(beam_agent_attachment_manifest, Prepared)),
    ?assert(lists:any(fun
        (#{<<"type">> := <<"resource_link">>}) -> true;
        (_) -> false
    end, maps:get(beam_agent_prompt_blocks, Prepared))),
    ok = beam_agent_session_store_core:delete_session(SessionId).

temp_path(Name) ->
    unicode:characters_to_binary(
        filename:join([os:getenv("TMPDIR", "/tmp"),
                       "beam_agent_attachments_" ++ integer_to_list(erlang:unique_integer([positive])) ++
                       "_" ++ binary_to_list(Name)])).
