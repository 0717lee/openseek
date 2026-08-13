///|
/// Project the application data that the transcript package renders. The
/// component owns scroll position; the root owns durable conversation data.
///
/// The component stays mounted while onboarding is on screen — the root view
/// simply does not place it — so a model with no conversation projects an
/// empty transcript rather than inventing one to read.
fn Model::transcript_input(self : Model) -> @transcript_component.Input {
  match self.screen {
    Dsh => {
      let root = self.dsh
        .active_workspace_path()
        .bind(path => @resource.of_path(@interop.ChannelId::Local, path))
      let session = self.dsh.active_id().unwrap_or("none")
      @transcript_component.Input(
        source=@transcript_component.Dsh,
        focused=@interop.ChannelId::Local,
        active_session=session,
        root~,
        submission_generation=0,
        items=@transcript_component.VisibleRow::history(
          self.dsh.transcript_items(),
        ),
        streaming_reasoning="",
        streaming_response=self.dsh.streaming_text(),
        streaming_identity=session,
        subruns=[],
      )
    }
    Codex => {
      let placement = self.codex.active_placement(self.focused)
      @transcript_component.Input(
        source=@transcript_component.Codex,
        focused=self.focused,
        active_session=self.codex.active_id().unwrap_or("none"),
        root=placement.bind(value => value.checkout_root()),
        submission_generation=0,
        items=@transcript_component.VisibleRow::history(
          self.codex.transcript_items(),
        ),
        streaming_response=None,
        streaming_identity="idle",
      )
    }
    _ =>
      match self.active_conversation() {
        None =>
          @transcript_component.Input(
            source=@transcript_component.OpenSeek,
            focused=self.focused,
            active_session=self.active_session,
            root=None,
            submission_generation=self.submission_sequence,
            items=[],
            streaming_response=None,
            streaming_identity="",
          )
        Some(conversation) => {
          let (streaming_reasoning, reasoning_complete) = conversation.reasoning_for_render()
          @transcript_component.Input(
            source=@transcript_component.OpenSeek,
            focused=self.focused,
            active_session=self.active_session,
            root=self
              .conversation_placement(conversation)
              .bind(value => value.checkout_root()),
            submission_generation=self.submission_sequence,
            items=conversation.visible_transcript_rows(),
            streaming_response=conversation.turn.streaming_response,
            streaming_reasoning?,
            reasoning_complete~,
            streaming_identity=conversation.streaming_render_identity(),
          )
        }
      }
  }
}
