defmodule BeamAgent.PromptCacheTest do
  use ExUnit.Case, async: false

  setup_all do
    assert Code.ensure_loaded?(BeamAgent.PromptCache)
    :ok
  end

  setup do
    BeamAgent.PromptCache.clear()
    :ok
  end

  test "exports the canonical prompt cache surface" do
    assert function_exported?(BeamAgent.PromptCache, :cached_query, 2)
    assert function_exported?(BeamAgent.PromptCache, :cached_query, 3)
    assert function_exported?(BeamAgent.PromptCache, :lookup, 2)
    assert function_exported?(BeamAgent.PromptCache, :lookup, 3)
    assert function_exported?(BeamAgent.PromptCache, :store, 4)
    assert function_exported?(BeamAgent.PromptCache, :invalidate, 2)
    assert function_exported?(BeamAgent.PromptCache, :invalidate, 3)
    assert function_exported?(BeamAgent.PromptCache, :clear, 0)
    assert function_exported?(BeamAgent.PromptCache, :stats, 0)
    assert function_exported?(BeamAgent.PromptCache, :evict_expired, 0)
  end

  test "clear/0 returns :ok" do
    assert :ok = BeamAgent.PromptCache.clear()
  end

  test "stats/0 returns initial zero counters" do
    stats = BeamAgent.PromptCache.stats()
    assert is_map(stats)
    assert stats.hits == 0
    assert stats.misses == 0
    assert stats.entries == 0
    assert stats.bytes_estimate == 0
  end

  test "store/4 + lookup/2 round-trip with dead pid" do
    pid = dead_pid()
    prompt = "What is OTP?"
    messages = [%{type: :text, content: "OTP is..."}]

    assert :ok = BeamAgent.PromptCache.store(pid, prompt, messages, %{})
    assert {:hit, ^messages, _meta} = BeamAgent.PromptCache.lookup(pid, prompt)
  end

  test "lookup/2 returns :miss on empty cache" do
    pid = dead_pid()
    assert :miss = BeamAgent.PromptCache.lookup(pid, "absent")
  end

  test "invalidate/2 removes cached entry" do
    pid = dead_pid()
    prompt = "to invalidate"

    :ok = BeamAgent.PromptCache.store(pid, prompt, [:data], %{})
    :ok = BeamAgent.PromptCache.invalidate(pid, prompt)
    assert :miss = BeamAgent.PromptCache.lookup(pid, prompt)
  end

  test "evict_expired/0 removes stale entries" do
    pid = dead_pid()
    :ok = BeamAgent.PromptCache.store(pid, "stale", [:old], %{cache_ttl: 1})
    Process.sleep(5)
    assert BeamAgent.PromptCache.evict_expired() >= 1
  end

  # Spawn a process that exits immediately — resolve_backend falls
  # back to <<"unknown">> for dead pids.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    Process.sleep(1)
    pid
  end
end
