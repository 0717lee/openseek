// The topbar's branch chip: ask the host for the git branch of a
// conversation's workspace through the `git.branch` method. Probed when a
// run starts (the workspace is created lazily on the first one), when a
// stored session opens, and when a run finishes (the agent may have created
// the repository or switched branches mid-turn). Any failure just reads as
// "no branch" — the chip hides.

///|
fn fetch_branch(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  cwd : @common.Uri?,
) -> @cmd.Cmd {
  match cwd {
    Some(resource) if !@resource.belongs_to(resource, channel) =>
      return @cmd.none
    _ => ()
  }
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply = @interop.bridge_request(channel, @commands.git_branch, {
        session,
        cwd: cwd.map(resource => resource.path),
      }) catch {
        _ => {
          scheduler.add(dispatch(BranchLoaded(session~, branch=None)))
          return
        }
      }
      scheduler.add(dispatch(BranchLoaded(session~, branch=reply.branch)))
    })
  })
}
