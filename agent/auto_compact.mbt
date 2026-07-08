///|
/// Share of the model context window, in percent, at which the loop
/// compacts. Auto-compaction is a context-ceiling guard, not a cost
/// optimization: appending a summary rewrites the model-facing prefix and
/// busts DeepSeek prefix-cache pricing, so it must fire only where the
/// alternative is request failure (improvement.md). The headroom left below
/// the ceiling must still fit the summary-generation request, which resends
/// the projected history plus the checkpoint prompt.
let auto_compact_threshold_percent = 80

///|
/// Compact the session when the last response reports token usage near the
/// model's context window.
///
/// The trigger reads `usage.total_tokens` — last prompt plus completion, the
/// closest available proxy for the next request's prompt — right after every
/// response, so a final-answer step still compacts and the next turn starts
/// from the checkpoint instead of creeping past the ceiling turn by turn.
///
/// Two stages, bounded per turn. The first folds only events before this
/// turn's task (`1..turn_start_sequence - 1`): the active task, steers, and
/// tool results stay verbatim in context. If pressure persists — or there is
/// no prior history — the second checkpoints everything so far, the same
/// lossy-but-designed semantic as the manual compact flow, whose prompt
/// carries current goal and intent forward. After that (or after a failed
/// summary) the guard disarms for the rest of the turn; the next turn's
/// fresh loop re-arms it.
///
/// Fail-open: a failed summary logs `auto_compaction_failed` and the turn
/// continues uncompacted — a guardrail must not kill a turn that might still
/// fit, and one that no longer fits fails visibly on the next main request.
/// Known limit: the guard reacts to reported usage, so a single oversized
/// tool result appended between responses can still overflow before the next
/// check; tool-output capping (todo.md) is the fix for that, not compaction.
///
/// The `auto_compaction_*` event names are deliberately distinct from the
/// manual flow's `compaction_*`: the TUI treats `compaction_finished` and
/// `compaction_failed` as terminal for the active run, which a mid-turn
/// auto-compaction is not.
async fn AgentLoop::maybe_auto_compact(
  self : Self,
  session : @agent_session.Session,
  usage : @deepseek.Usage,
) -> @agent_session.Session {
  if self.auto_compact_disarmed {
    return session
  }
  let context_window = self.client.model.context_window()
  if usage.total_tokens.to_int64() * 100 <
    context_window.to_int64() * auto_compact_threshold_percent.to_int64() {
    return session
  }
  let prior_prefix_end = self.turn_start_sequence - 1
  let to_sequence = if prior_prefix_end >= 1 &&
    self.auto_compacted_to < prior_prefix_end {
    prior_prefix_end
  } else {
    self.auto_compact_disarmed = true
    session.last_sequence()
  }
  @xlog.info() <?
    {
      "event": "auto_compaction_started",
      "from_sequence": 1,
      "to_sequence": to_sequence,
      "total_tokens": usage.total_tokens,
      "context_window": context_window,
    }
  let summary_source = if to_sequence == session.last_sequence() {
    session
  } else {
    session_prefix(session, to_sequence)
  }
  let summary = @compact.generate_compaction_summary(
    client=self.summary_client,
    summary_source,
  ) catch {
    error => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(error) {
        raise error
      }
      self.auto_compact_disarmed = true
      @xlog.warn() <? { "event": "auto_compaction_failed", "error": "\{error}" }
      return session
    }
  }
  // The preconditions hold by construction (the generator rejects empty
  // summaries; 1 <= to_sequence <= last_sequence), and persistence must go
  // through the loop's append seam, so `Session::compact`'s direct append is
  // not usable here. A raise from either half propagates like any other
  // append failure and closes the turn through the run-level handler.
  let item = session.summary_item(
    content=summary,
    from_sequence=1,
    to_sequence~,
  )
  let next = self.append(session, item)
  self.auto_compacted_to = to_sequence
  self.messages.clear()
  for message in next.chat_messages() {
    self.messages.push(message)
  }
  @xlog.info() <?
    {
      "event": "auto_compaction_finished",
      "from_sequence": 1,
      "to_sequence": to_sequence,
      "summary": summary,
    }
  next
}

///|
/// Rebuild events `1..to_sequence` as a standalone session so the checkpoint
/// request summarizes exactly the range the summary event will cover — not
/// the active turn it leaves verbatim. Re-appending a contiguous prefix
/// preserves its sequence numbers, so ranges inside earlier summary events
/// stay valid for the projection.
fn session_prefix(
  session : @agent_session.Session,
  to_sequence : Int,
) -> @agent_session.Session {
  for
    event in session.events()
    prefix = @agent_session.Session(
      session.id(),
      system_prompt=session.system_prompt(),
    ) {
    if event.sequence() <= to_sequence {
      continue prefix.append(event.item())
    }
    continue prefix
  } nobreak {
    prefix
  }
}
