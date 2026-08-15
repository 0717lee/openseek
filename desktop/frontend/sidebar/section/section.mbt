///|
pub(all) struct Id {
  source : String
  channel : String
} derive(Debug, Eq, Hash)

///|
pub fn Id::Id(source~ : String, channel~ : String) -> Id {
  { source, channel }
}

///|
pub fn Id::source(self : Id) -> String {
  self.source
}

///|
pub fn Id::channel(self : Id) -> String {
  self.channel
}

///|
/// The DOM child key for this section's heading inside the sidebar's one
/// keyed container.
pub fn Id::key(self : Id) -> String {
  "section:\{self.source}:\{self.channel}"
}

///|
pub(all) struct Placeholder {
  id : String
  label : String
  class_name : String
  nested : Bool
  openable : Bool
} derive(Debug, Eq)

///|
pub(all) enum Entry {
  Project(@project.Input)
  Conversation(@conversation.Input)
  Placeholder(Placeholder)
} derive(Debug, Eq)

///|
fn Entry::key(self : Entry) -> String {
  match self {
    Project(project) => {
      let id = project.id()
      "project:\{id.source()}:\{id.channel()}:\{id.root()}"
    }
    Conversation(conversation) => {
      let id = conversation.id()
      let root = id.root().unwrap_or("")
      "conversation:\{id.source()}:\{id.channel()}:\{id.conversation()}:\{root}"
    }
    Placeholder(row) => "placeholder:\{row.id}"
  }
}

///|
fn Entry::kind(self : Entry) -> String {
  match self {
    Project(_) => "project"
    Conversation(_) => "conversation"
    Placeholder(_) => "placeholder"
  }
}

///|
pub(all) struct Action {
  title : String
  disabled : Bool
} derive(Debug, Eq)

///|
pub(all) struct Input {
  id : Id
  label : String
  initially_collapsed : Bool
  selected : Bool
  action : Action?
  entries : Array[Entry]
} derive(Debug, Eq)

///|
pub fn Input::id(self : Input) -> Id {
  self.id
}

///|
pub(all) struct Actions {
  primary : (Id) -> @cmd.Cmd
  placeholder : (String) -> @cmd.Cmd
  project : @project.Actions
  conversation : @conversation.Actions
}

///|
priv enum Msg {
  Toggle
}

///|
priv struct State {
  collapsed : Bool
} derive(Eq)

///|
fn Actions::placeholder_component(
  self : Actions,
  input : @rabbita.Val[Placeholder],
) -> @rabbita.Val[Array[(String, @html.Html)]] {
  input.map(row => {
    let mut class = "conversation-row placeholder"
    if row.nested {
      class = class + " nested"
    }
    if !row.class_name.is_empty() {
      class = class + " " + row.class_name
    }
    let children : Array[@html.Html] = []
    if row.nested {
      children.push(@html.span(class="row-twisty spacer", ""))
    }
    children.push(@html.span(class="sidebar-label", row.label))
    [
      (
        "placeholder:\{row.id}",
        @html.div(
          class~,
          on_click=if row.openable {
            (self.placeholder)(row.id)
          } else {
            @cmd.none
          },
          children,
        ),
      ),
    ]
  })
}

///|
fn Actions::entry_component(
  self : Actions,
  _key : String,
  input : @rabbita.Val[Entry],
) -> @rabbita.Val[Array[(String, @html.Html)]] {
  input.switch_by(
    entry => {
      match entry {
        Project(initial) => {
          let project_input = input.map(entry => {
            match entry {
              Project(project) => project
              _ => initial
            }
          })
          @project.component(project_input, self.project)
        }
        Conversation(initial) => {
          let conversation_input = input.map(entry => {
            match entry {
              Conversation(conversation) => conversation
              _ => initial
            }
          })
          @conversation.component(conversation_input, self.conversation)
        }
        Placeholder(initial) => {
          let placeholder_input = input.map(entry => {
            match entry {
              Placeholder(placeholder) => placeholder
              _ => initial
            }
          })
          self.placeholder_component(placeholder_input)
        }
      }
    },
    by=entry => entry.kind(),
  )
}

///|
/// A Section is a keyed Rabbita component, not an array fragment rebuilt by
/// the root view. Its disclosure state survives entry insertion and reorder.
/// Rows are (key, node) pairs for the sidebar's one keyed container.
pub fn component(
  input : @rabbita.Val[Input],
  actions : Actions,
) -> @rabbita.Val[Array[(String, @html.Html)]] {
  let (state, emit) = @rabbita.create_state_with_input(
    input~,
    init=(_, input) => ({ collapsed: input.initially_collapsed }, @cmd.none),
    update=(state, _, msg, _) => {
      match msg {
        Toggle => ({ collapsed: !state.collapsed }, @cmd.none)
      }
    },
  )
  let entry_inputs = input.map(input => @vector.from_array(input.entries))
  let entry_rows = entry_inputs.assoc_by(
    (key, entry) => actions.entry_component(key, entry),
    by=entry => entry.key(),
  )
  state.map3(input, entry_rows, (state, input, entry_rows) => {
    // Selecting a section reveals it without resetting the user's stored
    // disclosure choice; leaving it restores the previous fold.
    let collapsed = state.collapsed && !input.selected
    let mut class = if collapsed {
      "sidebar-heading section-heading collapsible collapsed"
    } else {
      "sidebar-heading section-heading collapsible"
    }
    if input.selected {
      class = class + " active"
    }
    let heading : Array[@html.Html] = [
      @html.span(class="sidebar-label", input.label),
    ]
    if input.action is Some(action) {
      heading.push(
        @html.button(
          class="row-archive",
          type_="button",
          title=action.title,
          disabled=action.disabled,
          attrs=@html.Attrs::build().on_click(event => {
            event.stop_propagation()
            (actions.primary)(input.id)
          }),
          @icons.icon(@icons.icon_add),
        ),
      )
    }
    let rows : Array[(String, @html.Html)] = [
      (input.id.key(), @html.div(class~, on_click=emit(Toggle), heading)),
    ]
    if !collapsed {
      for group in entry_rows {
        for row in group {
          rows.push(row)
        }
      }
    }
    rows
  })
}
