// The picker's data source: ask the host to list one location's
// subdirectories. Unlike the file panel's `read_directory` this is not
// scoped to a conversation's workspace — its whole purpose is choosing a
// new workspace anywhere on the host, and the gateway's token already gates
// full host access. The frontend renders the picker itself, so desktop and
// browser share one flow and the directories shown are always the host
// machine's.

///|
/// Ask the host to list one location. `path` "" starts at the host's home
/// directory; "/" is a Windows host's drive list. `generation` rides along
/// on the reply with `channel`, so the state machine can drop answers to
/// superseded navigations and to a picker that was reopened for another
/// device.
fn browse(
  emit : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  path : String,
  generation~ : Int,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply = @interop.bridge_request(channel, @commands.fs_browse, {
        path: match path.trim() {
          "" => None
          value => Some(value.to_owned())
        },
      }) catch {
        error => {
          scheduler.add(
            emit(
              Failed(
                channel~,
                message=@interop.bridge_error_text(error),
                generation~,
              ),
            ),
          )
          return
        }
      }
      let message = match reply {
        Listing(path~, entries~, ..) => {
          if @resource.of_path(channel, path) is Some(path) {
            let entries = entries.filter(name => !name.is_empty())
            scheduler.add(
              emit(
                Loaded(
                  channel~,
                  location=Directory(path),
                  entries~,
                  generation~,
                ),
              ),
            )
            return
          }
          "malformed directory listing"
        }
        Drives(entries~) => {
          let entries = entries.filter(name => !name.is_empty())
          scheduler.add(
            emit(Loaded(channel~, location=DriveList, entries~, generation~)),
          )
          return
        }
        BrowseError(message) => message
      }
      scheduler.add(emit(Failed(channel~, message~, generation~)))
    })
  })
}

///|
/// The protocol path for one child of a directory the picker already
/// loaded. Resource URI paths always use `/`, including Windows drive
/// resources such as `/C:/code`.
fn @common.Uri::picker_child_path(self : @common.Uri, name : String) -> String {
  if self.path.has_suffix("/") {
    self.path + name
  } else {
    self.path + "/" + name
  }
}
