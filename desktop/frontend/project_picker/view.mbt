// The picker's modal, shaped like a system chooser: a clickable breadcrumb
// for the current directory (each segment navigates up to that level —
// there is no ".." row) and a folder list that navigates on click. On a
// Windows host the trail roots at "This PC", whose listing is the drive
// letters — the way to another drive. The keyboard surface lives in the
// document-level capture pair (`keys.mbt`): Enter adds the browsed
// directory, Escape closes, and a pasted path jumps straight to that
// location (a path that names no directory pops a toast). It renders the
// host machine's directories whichever gateway serves the page, so desktop
// and browser share the one flow. Clicks inside must not bubble to the
// backdrop, whose click closes the picker.

///|
pub fn view(emit : @cmd.Emit[Msg], picker : State) -> @html.Html {
  let rows : Array[@html.Html] = []
  for name in picker.entries {
    let target = match picker.location {
      Some(Directory(path)) => path.picker_child_path(name)
      // A drive row ("C:") enters that drive's root; the trailing slash is
      // the drive root's canonical resource spelling ("/C:/").
      Some(DriveList) => "/" + name + "/"
      None => name
    }
    rows.push(
      @html.div(class="picker-row", on_click=emit(Navigate(target)), [
        @html.span(class="picker-row-icon", @icons.icon(@icons.icon_folder)),
        @html.span(class="picker-row-name", name),
      ]),
    )
  }
  if picker.entries.length() == 0 {
    rows.push(
      @html.div(
        class="picker-empty",
        if picker.loading {
          "Loading…"
        } else {
          "No subfolders"
        },
      ),
    )
  }
  let children : Array[@html.Html] = [
    @html.div(class="modal-title", "Add a project"),
    picker_breadcrumbs(emit, picker),
  ]
  children.push(@html.div(class="picker-list", rows))
  children.push(
    @html.div(class="modal-actions", [
      @html.button(on_click=emit(Close), "Cancel"),
      @html.button(
        class="primary",
        // While a navigation is in flight the shown listing is stale, and
        // the drive list is not a directory anyone can register; `handle`
        // refuses the confirm too, this just says so visually.
        disabled=picker.loading || !(picker.location is Some(Directory(_))),
        on_click=emit(Confirm),
        match picker.location {
          Some(Directory(path)) =>
            "Add \u{201c}\{@resource.label(path)}\u{201d}"
          _ => "Add this folder"
        },
      ),
    ]),
  )
  @html.div(class="modal-backdrop", on_click=emit(Close), [
    @html.div(
      class="modal picker-modal",
      attrs=@html.Attrs::build().on_click(event => {
        event.stop_propagation()
        @cmd.none
      }),
      children,
    ),
  ])
}

///|
/// The current location as a clickable trail: every ancestor is a button
/// that navigates back up to it, the way a system chooser's path bar works.
/// POSIX paths root at `/`; Windows resource paths keep `/C:/` as their
/// drive root and root at the drive list ("This PC"), which is how another
/// drive letter is reached. UNC never reaches this UI because the backend
/// rejects it.
fn picker_breadcrumbs(emit : @cmd.Emit[Msg], picker : State) -> @html.Html {
  let crumbs : Array[@html.Html] = []
  guard picker.location is Some(location) else {
    return @html.div(class="picker-crumbs", crumbs)
  }
  guard location is Directory(resource) else {
    // The drive list is the trail's whole content while it is shown.
    crumbs.push(
      @html.button(
        class="picker-crumb current",
        on_click=emit(Navigate("/")),
        "This PC",
      ),
    )
    return @html.div(class="picker-crumbs", crumbs)
  }
  let path = resource.path

  let segments : Array[String] = []
  for part in path.split("/") {
    if !part.is_empty() {
      segments.push("\{part}")
    }
  }
  let drive_root = match segments {
    [drive, ..] if drive.length() == 2 && drive.has_suffix(":") => Some(drive)
    _ => None
  }
  crumbs.push(
    @html.button(
      class=if segments.length() == 0 {
        "picker-crumb current"
      } else {
        "picker-crumb"
      },
      on_click=emit(Navigate("/")),
      if drive_root is Some(_) {
        "This PC"
      } else {
        "/"
      },
    ),
  )
  let mut prefix = ""
  for index, segment in segments {
    prefix = if drive_root is Some(_) && index == 0 {
      "/" + segment + "/"
    } else if prefix.has_suffix("/") {
      prefix + segment
    } else {
      prefix + "/" + segment
    }
    if crumbs.length() > 0 {
      crumbs.push(@html.span(class="picker-crumb-sep", "›"))
    }
    crumbs.push(
      @html.button(
        class=if index == segments.length() - 1 {
          "picker-crumb current"
        } else {
          "picker-crumb"
        },
        on_click=emit(Navigate(prefix)),
        segment,
      ),
    )
  }
  @html.div(class="picker-crumbs", crumbs)
}
