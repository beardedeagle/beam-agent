-module(beam_agent_content).
-compile([nowarn_missing_spec]).
-moduledoc "Public wrapper for normalized content-block conversion inside `beam_agent`.".

-export([
    parse_blocks/1,
    block_to_message/1,
    message_to_block/1,
    flatten_assistant/1,
    messages_to_blocks/1,
    normalize_messages/1
]).

-export_type([content_block/0]).

-type content_block() :: beam_agent_content_core:content_block().

parse_blocks(Blocks) -> beam_agent_content_core:parse_blocks(Blocks).
block_to_message(Block) -> beam_agent_content_core:block_to_message(Block).
message_to_block(Message) -> beam_agent_content_core:message_to_block(Message).
flatten_assistant(Message) -> beam_agent_content_core:flatten_assistant(Message).
messages_to_blocks(Messages) -> beam_agent_content_core:messages_to_blocks(Messages).
normalize_messages(Messages) -> beam_agent_content_core:normalize_messages(Messages).
