// Shared sidebar rows accept already-built commands from their owner. They are
// transient view inputs, never application state: every render creates fresh
// virtual-DOM nodes and commands for the owning OpenSeek or Codex model.

///|
/// The optional trailing action owned by one collapsible section.
pub(all) struct SectionAction {
  title : String
  command : @cmd.Cmd
  disabled : Bool
}

///|
/// One peer section heading in the conversation list. The whole row folds its
/// section; an optional trailing action stops propagation before it runs, so
/// adding a workspace or conversation never also closes the section.
pub(all) struct Section {
  label : String
  toggle : @cmd.Cmd
  collapsed : Bool
  action : SectionAction?
  selected : Bool
}

///|
pub fn Section::render(self : Section) -> @html.Html {
  let mut class = if self.collapsed {
    "sidebar-heading section-heading collapsible collapsed"
  } else {
    "sidebar-heading section-heading collapsible"
  }
  if self.selected {
    class = class + " active"
  }
  let children : Array[@html.Html] = [
    @html.span(class="sidebar-label", self.label),
  ]
  if self.action is Some(action) {
    children.push(
      @html.button(
        class="row-archive",
        type_="button",
        title=action.title,
        disabled=action.disabled,
        attrs=@html.Attrs::build().on_click(event => {
          event.stop_propagation()
          action.command
        }),
        @icons.icon(@icons.icon_add),
      ),
    )
  }
  @html.div(class~, on_click=self.toggle, children)
}

///|
/// A conversation's optional archive control.
pub(all) struct ConversationArchive {
  title : String
  command : @cmd.Cmd
}

///|
/// Every conversation keeps the same leading disclosure slot. OpenSeek fills
/// it for subagent runs; another conversation source can retain the spacer.
pub(all) enum ConversationSubruns {
  NoSubruns
  Subruns(count~ : Int, expanded~ : Bool, toggle~ : @cmd.Cmd)
}

///|
/// One conversation row in the global sidebar. Its owner computes status and
/// actions; this package owns the DOM order, classes, and click propagation.
pub(all) struct ConversationRow {
  title : String
  label : String
  open : @cmd.Cmd
  nested : Bool
  subrun : Bool
  active : Bool
  running : Bool
  subruns : ConversationSubruns
  status : Array[@html.Html]
  archive : ConversationArchive?
}

///|
pub fn ConversationRow::render(self : ConversationRow) -> @html.Html {
  let mut class = "conversation-row"
  if self.nested {
    class = class + " nested"
  }
  if self.subrun {
    class = class + " subrun"
  }
  if self.active {
    class = class + " active"
  }
  if self.running {
    class = class + " running"
  }
  let twisty = match self.subruns {
    NoSubruns => @html.span(class="row-twisty spacer", "")
    Subruns(count~, expanded~, toggle~) =>
      @html.button(
        class=if expanded { "row-twisty expanded" } else { "row-twisty" },
        type_="button",
        title=if count == 1 {
          "1 subagent run"
        } else {
          "\{count} subagent runs"
        },
        attrs=@html.Attrs::build().on_click(event => {
          event.stop_propagation()
          toggle
        }),
        @icons.icon(@icons.icon_chevron_down),
      )
  }
  let children : Array[@html.Html] = [
    twisty,
    @html.span(class="sidebar-label", self.label),
  ]
  if !self.status.is_empty() || self.archive is Some(_) {
    let trailing : Array[@html.Html] = []
    if !self.status.is_empty() {
      trailing.push(@html.span(class="row-status", self.status))
    }
    if self.archive is Some(archive) {
      trailing.push(
        @html.span(class="row-actions", [
          @html.button(
            class="row-archive",
            type_="button",
            title=archive.title,
            attrs=@html.Attrs::build().on_click(event => {
              event.stop_propagation()
              archive.command
            }),
            @icons.icon(@icons.icon_archive),
          ),
        ]),
      )
    }
    children.push(@html.span(class="row-trailing", trailing))
  }
  @html.div(class~, title=self.title, on_click=self.open, children)
}

///|
/// One hover action belonging to a workspace row. The image is a function so
/// each render receives a fresh virtual-DOM value rather than sharing nodes.
pub(all) struct WorkspaceAction {
  title : String
  command : @cmd.Cmd
  image : () -> @html.Html
}

///|
fn WorkspaceAction::render(self : WorkspaceAction) -> @html.Html {
  @html.button(
    class="row-archive",
    type_="button",
    title=self.title,
    attrs=@html.Attrs::build().on_click(event => {
      event.stop_propagation()
      self.command
    }),
    @icons.icon(self.image),
  )
}

///|
/// A workspace row's overflow ("…") menu: the toggle button and, while
/// open, the dropdown body. The owner builds the body's items and holds the
/// open/closed state; this package keeps the button in the row's action
/// geometry and anchors the dropdown to the row. The body is a function so
/// each render receives a fresh virtual-DOM value.
pub(all) struct WorkspaceMenu {
  title : String
  open : Bool
  toggle : @cmd.Cmd
  body : () -> @html.Html
}

///|
/// Optional folder disclosure. OpenSeek project rows own one because their
/// chat previews fold independently; Codex workspace rows omit it because
/// they are labels, not another collapsible navigation level.
pub(all) struct WorkspaceDisclosure {
  collapsed : Bool
  toggle : @cmd.Cmd
}

///|
/// A folder row shared by workspace-like conversation groups. The owner
/// supplies actions, while this package keeps geometry and action slots equal.
pub(all) struct WorkspaceRow {
  title : String
  label : String
  active : Bool
  disclosure : WorkspaceDisclosure?
  menu : WorkspaceMenu?
  actions : Array[WorkspaceAction]
}

///|
pub fn WorkspaceRow::render(self : WorkspaceRow) -> @html.Html {
  let mut class = "workspace-row"
  if self.disclosure is Some(disclosure) {
    class = if disclosure.collapsed {
      class + " collapsible collapsed"
    } else {
      class + " collapsible"
    }
  }
  if self.active {
    class = class + " active"
  }
  if self.menu is Some(menu) && menu.open {
    // Keeps the hover-revealed action slots visible while the menu floats,
    // even once the pointer moves into it.
    class = class + " menu-open"
  }
  let children : Array[@html.Html] = match self.disclosure {
    Some(disclosure) =>
      [
        @html.button(
          class="workspace-disclosure",
          type_="button",
          title=self.title,
          on_click=disclosure.toggle,
          attrs=@html.Attrs::build().aria_expanded(
            (!disclosure.collapsed).to_string(),
          ),
          [
            @html.span(class="sidebar-icon", @icons.icon(@icons.icon_folder)),
            @html.span(class="sidebar-label", self.label),
          ],
        ),
      ]
    None =>
      [
        @html.span(class="sidebar-icon", @icons.icon(@icons.icon_folder)),
        @html.span(class="sidebar-label", self.label),
      ]
  }
  if self.menu is Some(menu) {
    children.push(
      @html.button(
        class=if menu.open {
          "row-archive workspace-menu-button open"
        } else {
          "row-archive workspace-menu-button"
        },
        type_="button",
        title=menu.title,
        attrs=@html.Attrs::build().on_click(event => {
          event.stop_propagation()
          menu.toggle
        }),
        @icons.icon(@icons.icon_more),
      ),
    )
  }
  for action in self.actions {
    children.push(action.render())
  }
  // The open dropdown appends after the stable children, so opening and
  // closing it never re-keys the buttons under the pointer.
  if self.menu is Some(menu) && menu.open {
    children.push((menu.body)())
  }
  @html.div(class~, title=self.title, children)
}

///|
/// A non-conversation line in a section, used for loading, empty, and
/// unavailable states. Optional nesting keeps an empty workspace aligned with
/// the conversations that will replace it.
pub(all) struct PlaceholderRow {
  label : String
  class_name : String
  nested : Bool
  open : @cmd.Cmd?
}

///|
pub fn PlaceholderRow::render(self : PlaceholderRow) -> @html.Html {
  let mut class = "conversation-row placeholder"
  if self.nested {
    class = class + " nested"
  }
  if !self.class_name.is_empty() {
    class = class + " " + self.class_name
  }
  let children : Array[@html.Html] = []
  if self.nested {
    children.push(@html.span(class="row-twisty spacer", ""))
  }
  children.push(@html.span(class="sidebar-label", self.label))
  match self.open {
    Some(open) => @html.div(class~, on_click=open, children)
    None => @html.div(class~, children)
  }
}

///|
/// One ordered item in a collapsible sidebar section. Domain packages provide
/// plain row values; this enum is the only place that decides how a mixed list
/// turns into DOM.
pub(all) enum Entry {
  Workspace(WorkspaceRow)
  Conversation(ConversationRow)
  Placeholder(PlaceholderRow)
  Custom(@html.Html)
}

///|
pub fn Entry::render(self : Entry) -> @html.Html {
  match self {
    Workspace(row) => row.render()
    Conversation(row) => row.render()
    Placeholder(row) => row.render()
    Custom(html) => html
  }
}

///|
/// A workspace followed by its conversations. The group inserts one shared
/// nested placeholder when an attached workspace is empty.
pub(all) struct WorkspaceGroup {
  workspace : WorkspaceRow
  conversations : Array[ConversationRow]
  empty : PlaceholderRow?
}

///|
pub fn WorkspaceGroup::entries(self : WorkspaceGroup) -> Array[Entry] {
  let entries : Array[Entry] = [Workspace(self.workspace)]
  // Folder disclosure owns the whole group, so callers cannot accidentally
  // leave a placeholder or conversation visible below a collapsed project.
  if self.workspace.disclosure is Some(disclosure) && disclosure.collapsed {
    return entries
  }
  if self.conversations.is_empty() && self.empty is Some(empty) {
    entries.push(Placeholder(empty))
  } else {
    for row in self.conversations {
      entries.push(Conversation(row))
    }
  }
  entries
}

///|
/// A heading and its ordered body. Folding is implemented here once for
/// Projects, Codex, Chats, and Archived chats instead of at every call site.
pub(all) struct SectionList {
  section : Section
  entries : Array[Entry]
}

///|
pub fn SectionList::render(self : SectionList) -> Array[@html.Html] {
  let rows : Array[@html.Html] = [self.section.render()]
  if !self.section.collapsed {
    for entry in self.entries {
      rows.push(entry.render())
    }
  }
  rows
}

///|
/// The sidebar's peer sections in display order. Every source contributes
/// section data; this value owns their flattening into the one scroll lane.
pub(all) struct SidebarList {
  sections : Array[SectionList]
}

///|
pub fn SidebarList::render(self : SidebarList) -> Array[@html.Html] {
  let rows : Array[@html.Html] = []
  for section in self.sections {
    for row in section.render() {
      rows.push(row)
    }
  }
  rows
}
