///|
test "the sidebar input keeps peer sections in one component value" {
  let input : Input = {
    notices: [],
    sections: [
      {
        id: @section.Id(source="projects", channel="local"),
        label: "Projects",
        initially_collapsed: false,
        selected: false,
        action: None,
        entries: [],
      },
      {
        id: @section.Id(source="codex", channel="local"),
        label: "Codex",
        initially_collapsed: false,
        selected: true,
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
  assert_eq(input.sections[0].id().source(), "projects")
  assert_eq(input.sections[1].id().source(), "codex")
}
