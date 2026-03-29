-module(beam_agent_attachments_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Gemini: canonical prompt blocks with resource types
%%====================================================================

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

%%====================================================================
%% Native: Codex keeps attachments untouched
%%====================================================================

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

%%====================================================================
%% Claude: native content blocks
%%====================================================================

claude_text_attachment_produces_text_block_test() ->
    SessionId = <<"attachments-claude-text">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => text, text => <<"inline note">>}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Explain">>, Params),
    %% Prompt is NOT augmented (no text appendix)
    ?assertEqual(<<"Explain">>, Prompt),
    ?assertEqual(error, maps:find(attachments, Prepared)),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    ?assertMatch([
        #{<<"type">> := <<"text">>, <<"text">> := <<"Explain">>},
        #{<<"type">> := <<"text">>, <<"text">> := <<"inline note">>}
    ], PromptBlocks),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_image_attachment_produces_base64_block_test() ->
    SessionId = <<"attachments-claude-image">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"test.png">>),
    %% Write a minimal binary payload (not a real PNG, but tests the base64 path)
    ok = file:write_file(binary_to_list(TmpFile), <<137, 80, 78, 71, 0, 1, 2, 3>>),
    Params = #{attachments => [#{type => image, path => TmpFile}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Describe">>, Params),
    ?assertEqual(<<"Describe">>, Prompt),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% First block: prompt text, second block: image
    ?assertMatch([
        #{<<"type">> := <<"text">>, <<"text">> := <<"Describe">>},
        #{<<"type">> := <<"image">>, <<"mimeType">> := <<"image/png">>}
    ], PromptBlocks),
    %% Verify the image block has base64-encoded data
    [_, ImageBlock] = PromptBlocks,
    ?assert(is_binary(maps:get(<<"data">>, ImageBlock))),
    ok = file:delete(binary_to_list(TmpFile)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_file_attachment_inlines_text_content_test() ->
    SessionId = <<"attachments-claude-file">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"readme.md">>),
    ok = file:write_file(binary_to_list(TmpFile), <<"# Hello\nWorld">>),
    Params = #{attachments => [#{type => file, path => TmpFile, name => <<"readme.md">>}]},
    {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Review">>, Params),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% File should be inlined as text with filename wrapper
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            binary:match(Text, <<"--- readme.md ---">>) =/= nomatch
            andalso binary:match(Text, <<"# Hello">>) =/= nomatch;
        (_) -> false
    end, PromptBlocks)),
    ok = file:delete(binary_to_list(TmpFile)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_binary_file_attachment_describes_as_text_test() ->
    SessionId = <<"attachments-claude-binfile">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"data.bin">>),
    %% Write invalid UTF-8 to force the binary fallback path
    ok = file:write_file(binary_to_list(TmpFile), <<0, 255, 254, 253, 128, 129>>),
    Params = #{attachments => [#{type => file, path => TmpFile}]},
    {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Analyze">>, Params),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% Should have a text description block for the binary file
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            binary:match(Text, <<"binary file">>) =/= nomatch;
        (_) -> false
    end, PromptBlocks)),
    ok = file:delete(binary_to_list(TmpFile)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_missing_file_attachment_describes_as_text_test() ->
    SessionId = <<"attachments-claude-nofile">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => file, path => <<"/nonexistent/path.txt">>}]},
    {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Review">>, Params),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% Should gracefully produce a text description
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            binary:match(Text, <<"file:">>) =/= nomatch;
        (_) -> false
    end, PromptBlocks)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_audio_attachment_renders_as_text_test() ->
    SessionId = <<"attachments-claude-audio">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => audio, path => <<"/tmp/voice.wav">>}]},
    {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Transcribe">>, Params),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            binary:match(Text, <<"audio">>) =/= nomatch;
        (_) -> false
    end, PromptBlocks)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_mention_attachment_renders_as_text_test() ->
    SessionId = <<"attachments-claude-mention">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => mention, name => <<"repo">>, path => <<"app://repo">>}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Explain">>, Params),
    %% Prompt is NOT augmented for Claude (no text appendix)
    ?assertEqual(<<"Explain">>, Prompt),
    ?assertEqual(error, maps:find(attachments, Prepared)),
    ?assertMatch([#{type := mention, mention := <<"repo">>}],
        maps:get(beam_agent_attachment_blocks, Prepared)),
    ?assertMatch([#{type := mention, mention := <<"repo">>}],
        maps:get(beam_agent_attachment_manifest, Prepared)),
    %% Claude renders mentions as text, not resource_link
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    ?assert(lists:any(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            binary:match(Text, <<"mention">>) =/= nomatch;
        (_) -> false
    end, PromptBlocks)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_mixed_attachments_produce_correct_blocks_test() ->
    SessionId = <<"attachments-claude-mixed">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpImage = temp_path(<<"photo.png">>),
    ok = file:write_file(binary_to_list(TmpImage), <<137, 80, 78, 71, 0>>),
    TmpFile = temp_path(<<"notes.txt">>),
    ok = file:write_file(binary_to_list(TmpFile), <<"some notes here">>),
    Params = #{attachments => [
        #{type => text, text => <<"context">>},
        #{type => image, path => TmpImage},
        #{type => file, path => TmpFile, name => <<"notes.txt">>}
    ]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Analyze">>, Params),
    ?assertEqual(<<"Analyze">>, Prompt),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% First block: prompt, then text attachment, then image, then inlined file
    ?assertEqual(4, length(PromptBlocks)),
    [PromptBlock, TextBlock, ImageBlock, FileBlock] = PromptBlocks,
    ?assertMatch(#{<<"type">> := <<"text">>, <<"text">> := <<"Analyze">>}, PromptBlock),
    ?assertMatch(#{<<"type">> := <<"text">>, <<"text">> := <<"context">>}, TextBlock),
    ?assertMatch(#{<<"type">> := <<"image">>}, ImageBlock),
    ?assertMatch(#{<<"type">> := <<"text">>}, FileBlock),
    %% File block should contain the inlined content
    #{<<"text">> := FileText} = FileBlock,
    ?assertNotEqual(nomatch, binary:match(FileText, <<"some notes here">>)),
    ok = file:delete(binary_to_list(TmpImage)),
    ok = file:delete(binary_to_list(TmpFile)),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_empty_prompt_with_attachments_test() ->
    SessionId = <<"attachments-claude-empty-prompt">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{attachments => [#{type => text, text => <<"just this">>}]},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<>>, Params),
    ?assertEqual(<<>>, Prompt),
    PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
    %% Empty prompt is omitted, only the attachment block
    ?assertMatch([#{<<"type">> := <<"text">>, <<"text">> := <<"just this">>}], PromptBlocks),
    ok = beam_agent_session_store_core:delete_session(SessionId).

claude_no_attachments_passes_through_test() ->
    SessionId = <<"attachments-claude-none">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    Params = #{some_option => true},
    {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Hello">>, Params),
    ?assertEqual(<<"Hello">>, Prompt),
    ?assertEqual(Params, Prepared),
    ok = beam_agent_session_store_core:delete_session(SessionId).

%%====================================================================
%% Attachment size gating
%%====================================================================

claude_oversized_file_produces_rejection_block_test() ->
    SessionId = <<"attachments-claude-oversize">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"large.txt">>),
    %% Write 200 bytes, then set limit to 100 so the file is rejected
    Content = binary:copy(<<"x">>, 200),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 100),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"large.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Review">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"attachment rejected">>) =/= nomatch
                andalso binary:match(Text, <<"large.txt">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

gemini_oversized_file_produces_rejection_block_test() ->
    SessionId = <<"attachments-gemini-oversize">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => gemini
    }),
    TmpFile = temp_path(<<"big_resource.dat">>),
    Content = binary:copy(<<"y">>, 300),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 50),
    try
        Params = #{attachments => [#{type => file, path => TmpFile}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Analyze">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"attachment rejected">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

claude_oversized_image_produces_rejection_block_test() ->
    SessionId = <<"attachments-claude-oversize-img">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"big_photo.png">>),
    Content = binary:copy(<<0>>, 500),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 100),
    try
        Params = #{attachments => [#{type => image, path => TmpFile, name => <<"big_photo.png">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Describe">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"attachment rejected">>) =/= nomatch
                andalso binary:match(Text, <<"big_photo.png">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

file_at_size_limit_is_accepted_test() ->
    SessionId = <<"attachments-claude-atlimit">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"exact.txt">>),
    %% Write exactly 100 bytes, set limit to 100 — should pass (not >)
    Content = binary:copy(<<"z">>, 100),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 100),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"exact.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        %% File at limit should be inlined, NOT rejected
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"exact.txt">>) =/= nomatch
                andalso binary:match(Text, <<"attachment rejected">>) =:= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

file_under_limit_is_accepted_test() ->
    SessionId = <<"attachments-claude-underlimit">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"small.txt">>),
    Content = <<"tiny file">>,
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 1000),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"small.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        %% Should be inlined with content
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"tiny file">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

default_limit_is_512kb_test() ->
    %% Save prior env value so we can restore it after the test
    Prev = application:get_env(beam_agent, max_attachment_size),
    application:unset_env(beam_agent, max_attachment_size),
    SessionId = <<"attachments-default-limit">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"within_default.txt">>),
    %% 100 bytes is well within the 512 KB default
    ok = file:write_file(binary_to_list(TmpFile), <<"hello">>),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"within_default.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        %% Should be inlined, not rejected
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"hello">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        case Prev of
            {ok, V} -> application:set_env(beam_agent, max_attachment_size, V);
            undefined -> application:unset_env(beam_agent, max_attachment_size)
        end,
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

rejection_text_includes_human_readable_sizes_test() ->
    SessionId = <<"attachments-rejection-text">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"big_enough.txt">>),
    Content = binary:copy(<<"a">>, 2000),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    ok = application:set_env(beam_agent, max_attachment_size, 500),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"big_enough.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        [RejectionBlock] = [B || #{<<"type">> := <<"text">>, <<"text">> := T} = B <- PromptBlocks,
                                  binary:match(T, <<"attachment rejected">>) =/= nomatch],
        RejText = maps:get(<<"text">>, RejectionBlock),
        %% 2000 bytes → "2.0 KB", 500 bytes → "500 B"
        ?assertNotEqual(nomatch, binary:match(RejText, <<"KB">>)),
        ?assertNotEqual(nomatch, binary:match(RejText, <<"500 B">>))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

native_backend_ignores_size_gating_test() ->
    %% Native backends (codex, opencode, copilot) pass attachments through
    %% unchanged — size gating only applies to materialized backends
    SessionId = <<"attachments-codex-nogate">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => codex
    }),
    ok = application:set_env(beam_agent, max_attachment_size, 1),
    try
        Params = #{attachments => [#{type => file, path => <<"/tmp/any.txt">>}]},
        {Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Go">>, Params),
        ?assertEqual(<<"Go">>, Prompt),
        %% Native backend passes through — no materialization, no size check
        ?assertEqual({ok, [#{type => file, path => <<"/tmp/any.txt">>}]},
            maps:find(attachments, Prepared))
    after
        application:unset_env(beam_agent, max_attachment_size),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

infinity_disables_size_gating_test() ->
    SessionId = <<"attachments-claude-infinity">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"big_allowed.txt">>),
    Content = binary:copy(<<"x">>, 2000),
    ok = file:write_file(binary_to_list(TmpFile), Content),
    %% infinity disables the limit entirely — 2000 bytes should pass
    ok = application:set_env(beam_agent, max_attachment_size, infinity),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"big_allowed.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        %% Should be inlined, NOT rejected
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"big_allowed.txt">>) =/= nomatch
                andalso binary:match(Text, <<"attachment rejected">>) =:= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

invalid_env_falls_back_to_default_test() ->
    SessionId = <<"attachments-claude-badenv">>,
    ok = beam_agent_session_store_core:register_session(SessionId, #{
        session_id => SessionId,
        backend => claude
    }),
    TmpFile = temp_path(<<"safe.txt">>),
    ok = file:write_file(binary_to_list(TmpFile), <<"ok">>),
    %% Invalid env value (binary) should fall back to 512 KB default
    ok = application:set_env(beam_agent, max_attachment_size, <<"not_a_number">>),
    try
        Params = #{attachments => [#{type => file, path => TmpFile, name => <<"safe.txt">>}]},
        {_Prompt, Prepared} = beam_agent_attachments:prepare(SessionId, <<"Read">>, Params),
        PromptBlocks = maps:get(beam_agent_prompt_blocks, Prepared),
        %% Should succeed (2 bytes is under 512 KB default fallback)
        ?assert(lists:any(fun
            (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
                binary:match(Text, <<"ok">>) =/= nomatch;
            (_) -> false
        end, PromptBlocks))
    after
        application:unset_env(beam_agent, max_attachment_size),
        _ = file:delete(binary_to_list(TmpFile)),
        ok = beam_agent_session_store_core:delete_session(SessionId)
    end.

%%====================================================================
%% Helpers
%%====================================================================

temp_path(Name) ->
    unicode:characters_to_binary(
        filename:join([os:getenv("TMPDIR", "/tmp"),
                       "beam_agent_attachments_" ++ integer_to_list(erlang:unique_integer([positive])) ++
                       "_" ++ binary_to_list(Name)])).
