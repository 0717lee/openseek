// The Skills panel's commands: browsing the mooncakes.io registry and
// managing the engine's global skills library through the host's skill ops.
// All four are plain request/reply calls on the engine-host bridge.

///|
/// Fetch the registry's catalog of installable skills.
fn fetch_skills_catalog(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @protocol.EmptyPayload::{  }
      let raw_reply = @interop.bridge_request("skills_catalog", payload) catch {
        error => {
          scheduler.add(
            dispatch(SkillsCatalogFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      let reply : @protocol.SkillsCatalogReply? = @interop.bridge_reply(
        raw_reply,
      )
      match reply {
        Some(reply) =>
          scheduler.add(
            dispatch(
              SkillsCatalogLoaded(@transcript.skills_catalog_from_reply(reply)),
            ),
          )
        None =>
          scheduler.add(
            dispatch(SkillsCatalogFailed("malformed skill catalog")),
          )
      }
    })
  })
}

///|
/// Refresh the local skills library's contents.
fn fetch_installed_skills(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @protocol.EmptyPayload::{  }
      let raw_reply = @interop.bridge_request("skills_installed", payload) catch {
        error => {
          scheduler.add(
            dispatch(SkillsNotice(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      let reply : @protocol.InstalledSkillsReply? = @interop.bridge_reply(
        raw_reply,
      )
      match reply {
        Some(reply) =>
          scheduler.add(
            dispatch(
              InstalledSkillsLoaded(
                @transcript.installed_skills_from_reply(reply),
              ),
            ),
          )
        None =>
          scheduler.add(
            dispatch(SkillsNotice("malformed installed-skill list")),
          )
      }
    })
  })
}

///|
/// Install one catalog entry into the global skills library. Settles with a
/// `SkillActionDone` either way; the busy key is the entry's source label.
fn install_skill(
  dispatch : @cmd.Emit[Msg],
  item : @transcript.MarketSkillItem,
) -> @cmd.Cmd {
  let key = @transcript.market_source_label(item)
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.InstallSkillPayload = {
        module_name: item.module_name,
        version: item.version,
        package_path: if item.package_path.is_empty() {
          None
        } else {
          Some(item.package_path)
        },
      }
      let _ : @js.Value = @interop.bridge_request("skill_install", payload) catch {
        error => {
          scheduler.add(
            dispatch(
              SkillActionDone(key~, error=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      scheduler.add(dispatch(SkillActionDone(key~, error="")))
    })
  })
}

///|
/// Remove one registry-installed skill from the library; the busy key is
/// the library entry's id.
fn uninstall_skill(dispatch : @cmd.Emit[Msg], id : String) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload : @protocol.UninstallSkillPayload = { id, }
      let _ : @js.Value = @interop.bridge_request("skill_uninstall", payload) catch {
        error => {
          scheduler.add(
            dispatch(
              SkillActionDone(key=id, error=@interop.bridge_error_text(error)),
            ),
          )
          return
        }
      }
      scheduler.add(dispatch(SkillActionDone(key=id, error="")))
    })
  })
}
