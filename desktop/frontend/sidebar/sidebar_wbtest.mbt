///|
test "the sidebar input keeps peer sections in one component value" {
  let input : Input = {
    notices: [],
    sections: [
      {
        id: @section.Id(source="openseek.projects", channel="local"),
        label: "Projects",
        initially_collapsed: false,
        activation: None,
        action: None,
        entries: [],
      },
      {
        id: @section.Id(source="archived", channel="local"),
        label: "Archived chats",
        initially_collapsed: true,
        activation: Some("desktop-test"),
        action: None,
        entries: [],
      },
    ],
    update_label: None,
    update_enabled: false,
    skills_active: false,
    settings_active: false,
    account: None,
  }
  assert_eq(input.sections.length(), 2)
  assert_eq(input.sections[0].id().source(), "openseek.projects")
  assert_eq(input.sections[1].id().source(), "archived")
}

///|
#warnings("-alert_unstable")
test "the header add control names the project action" {
  let actions : Actions = {
    toggle: @cmd.none,
    new_chat: @cmd.none,
    update: @cmd.none,
    open_skills: @cmd.none,
    open_settings: @cmd.none,
    refresh_account: @cmd.none,
    sign_out: @cmd.none,
    section: {
      primary: _ => @cmd.none,
      placeholder: _ => @cmd.none,
      project: {
        new_conversation: _ => @cmd.none,
        open_settings: _ => @cmd.none,
        detach: _ => @cmd.none,
        conversation: {
          open: _ => @cmd.none,
          archive: _ => @cmd.none,
          restore: _ => @cmd.none,
          delete: _ => @cmd.none,
        },
      },
      conversation: {
        open: _ => @cmd.none,
        archive: _ => @cmd.none,
        restore: _ => @cmd.none,
        delete: _ => @cmd.none,
      },
    },
  }
  let input : Input = {
    notices: [],
    sections: [],
    update_label: None,
    update_enabled: false,
    skills_active: false,
    settings_active: false,
    account: None,
  }
  let html = @rabbita.render_to_string(() => {
    component(@rabbita.Val::constant(input), actions)
  })
  assert_true(html.contains("title=\"Add a project\""))
  assert_true(html.contains("aria-label=\"Add a project\""))
  assert_false(html.contains("title=\"New chat\""))
}
