// The topbar's branch chip: ask the host for the git branch of a
// conversation's workspace through the `workspace_branch` op. Probed when a
// run starts (the workspace is created lazily on the first one), when a
// stored session opens, and when a run finishes (the agent may have created
// the repository or switched branches mid-turn). Any failure just reads as
// "no branch" — the chip hides.

///|
fn fetch_branch(
  dispatch : @cmd.Emit[Msg],
  session : String,
  cwd : @pathx.Absolute?,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.WorkspaceBranchPayload = {
        session,
        cwd: workspace_token(cwd),
      }
      let raw_reply = @interop.bridge_request("workspace_branch", payload) catch {
        _ => {
          scheduler.add(dispatch(BranchLoaded(session~, branch=None)))
          return
        }
      }
      let reply : @protocol.WorkspaceBranchReply? = @interop.bridge_reply(
        raw_reply,
      )
      scheduler.add(
        dispatch(
          BranchLoaded(session~, branch=reply.map(reply => reply.branch)),
        ),
      )
    })
  })
}
