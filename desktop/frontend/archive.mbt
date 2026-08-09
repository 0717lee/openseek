// The sidebar's archive flow: `archive_session` asks the host to move a
// conversation's durable record into its store's `archived` twin,
// `unarchive_session` moves it back, and `archived_sessions` reads the
// archived conversations back. Successful ops reply with archived groups in
// the same shape as `list_sessions`; archive can instead return a structured
// dirty-checkout confirmation state. Since the actions move records between
// the stores the sidebar lists, both commands refresh the live list too.

///|
fn fetch_archived(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  connection_generation : Int,
  request_generation : Int,
) -> @cmd.Cmd {
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // A host without the op (or without a session store) just reads as an
      // empty Archived group.
      let reply = @interop.bridge_request(
        channel,
        @commands.session_list_archived,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        _ => return
      }
      scheduler.add(
        dispatch(
          ArchivedLoaded(
            @transcript.sessions_from_reply(reply, channel),
            connection_generation~,
            request_generation~,
            fresh_session=generated_session_id(),
          ),
        ),
      )
    })
  })
}

///|
fn archive_session(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  connection_generation : Int,
  sessions_request_generation : Int,
  archived_request_generation : Int,
  force? : Bool = false,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      archive_session_into(
        scheduler, dispatch, channel, session, connection_generation, sessions_request_generation,
        archived_request_generation, force,
      )
    })
  })
}

///|
async fn archive_session_into(
  scheduler : &@cmd.Scheduler,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  connection_generation : Int,
  sessions_request_generation : Int,
  archived_request_generation : Int,
  force : Bool,
) -> Unit noraise {
  let reply = @interop.bridge_request(
    channel,
    @commands.session_archive,
    // Archiving removes the conversation's checkout but retains its placement;
    // the retry after the discard-confirmation dialog carries force on the
    // wire.
    { session, force: if force { Some(true) } else { None } },
  ) catch {
    error => {
      scheduler.add(
        dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))(
          ArchiveFailed(@interop.bridge_error_text(error)),
        ),
      )
      return
    }
  }
  match reply {
    NeedsForce(refusal) =>
      scheduler.add(
        dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))(
          ArchiveNeedsForce(session~, refusal~),
        ),
      )
    Archived(reply) =>
      apply_archive_list_reply(
        scheduler, dispatch, channel, reply, connection_generation, sessions_request_generation,
        archived_request_generation,
      )
  }
}

///|
fn unarchive_session(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  connection_generation : Int,
  sessions_request_generation : Int,
  archived_request_generation : Int,
) -> @cmd.Cmd {
  archive_action(
    dispatch,
    channel,
    @commands.session_unarchive,
    { session, force: None },
    connection_generation,
    sessions_request_generation,
    archived_request_generation,
  )
}

///|
fn archive_action(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  command : @commands.Command[@protocol.SessionPayload, @protocol.SessionsReply],
  payload : @protocol.SessionPayload,
  connection_generation : Int,
  sessions_request_generation : Int,
  archived_request_generation : Int,
) -> @cmd.Cmd {
  let device_dispatch = dispatch.map((msg : DeviceMsg) => {
    FromDevice(channel, msg)
  })
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply = @interop.bridge_request(channel, command, payload) catch {
        error => {
          scheduler.add(
            device_dispatch(ArchiveFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      apply_archive_list_reply(
        scheduler, dispatch, channel, reply, connection_generation, sessions_request_generation,
        archived_request_generation,
      )
    })
  })
}

///|
/// Fold the archived-list reply from a successful archive/unarchive, then
/// refresh the live list that the record move made stale.
async fn apply_archive_list_reply(
  scheduler : &@cmd.Scheduler,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  reply : @protocol.SessionsReply,
  connection_generation : Int,
  sessions_request_generation : Int,
  archived_request_generation : Int,
) -> Unit noraise {
  scheduler.add(
    dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))(
      ArchivedLoaded(
        @transcript.sessions_from_reply(reply, channel),
        connection_generation~,
        request_generation=archived_request_generation,
        fresh_session=generated_session_id(),
      ),
    ),
  )
  // The record moved between the live and archived stores; the sidebar's
  // live list is stale until re-fetched.
  refresh_sessions_into(
    scheduler, dispatch, channel, connection_generation, sessions_request_generation,
  )
}
