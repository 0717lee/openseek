///|
#warnings("-alert_unstable")
test "section keeps disclosure and action controls separate" {
  let html = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      Section::{
        label: "Projects",
        toggle: @cmd.none,
        collapsed: true,
        action: Some({
          title: "Add a project",
          command: @cmd.none,
          disabled: false,
        }),
        selected: true,
      }.render(),
    )
  })
  assert_true(
    html.contains(
      "sidebar-heading section-heading collapsible collapsed active",
    ),
  )
  assert_true(html.contains(">Projects</span>"))
  assert_true(html.contains("title=\"Add a project\""))
}

///|
#warnings("-alert_unstable")
test "conversation row preserves disclosure status and archive slots" {
  let html = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      ConversationRow::{
        title: "thread-1",
        label: "Inspect changes",
        open: @cmd.none,
        nested: true,
        subrun: false,
        active: true,
        running: true,
        subruns: Subruns(count=2, expanded=true, toggle=@cmd.none),
        status: [@html.span(class="run-dot accent pulse", "")],
        archive: Some({ title: "Archive conversation", command: @cmd.none }),
      }.render(),
    )
  })
  assert_true(html.contains("conversation-row nested active running"))
  assert_true(html.contains("row-twisty expanded"))
  assert_true(html.contains("2 subagent runs"))
  assert_true(html.contains("row-status"))
  assert_true(html.contains("row-actions"))
  assert_true(html.contains("title=\"Archive conversation\""))
}

///|
#warnings("-alert_unstable")
test "workspace actions retain their declared order" {
  let html = @rabbita.render_to_string(() => {
    @rabbita.Val::constant(
      WorkspaceRow::{
        title: "/workspace",
        label: "workspace",
        active: false,
        actions: [
          { title: "Detach", command: @cmd.none, image: @icons.icon_close },
          {
            title: "New conversation",
            command: @cmd.none,
            image: @icons.icon_add,
          },
        ],
      }.render(),
    )
  })
  let detach = html.find("title=\"Detach\"").unwrap()
  let create = html.find("title=\"New conversation\"").unwrap()
  assert_true(detach < create)
}
