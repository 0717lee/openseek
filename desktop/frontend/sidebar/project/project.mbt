///|
/// A project component key includes its source. The OpenSeek Projects section
/// and the Codex section may point at the same directory, but they are two
/// independent UI branches and must not share disclosure or preview state.
pub(all) struct Id {
  source : String
  channel : String
  root : String
} derive(Debug, Eq, Hash)

///|
pub fn Id::Id(source~ : String, channel~ : String, root~ : String) -> Id {
  { source, channel, root }
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
pub fn Id::root(self : Id) -> String {
  self.root
}

///|
fn Id::subscription_key(self : Id) -> String {
  "sidebar-project-menu:\{self.source}:\{self.channel}:\{self.root}"
}

///|
pub(all) struct Input {
  id : Id
  title : String
  label : String
  active : Bool
  can_start : Bool
  managed : Bool
  conversations : Array[@conversation.Input]
  empty_label : String?
} derive(Debug, Eq)

///|
pub fn Input::id(self : Input) -> Id {
  self.id
}

///|
pub(all) struct Actions {
  new_conversation : (Id) -> @cmd.Cmd
  open_settings : (Id) -> @cmd.Cmd
  detach : (Id) -> @cmd.Cmd
  conversation : @conversation.Actions
}

///|
priv enum Msg {
  ToggleDisclosure
  ShowMore
  ToggleMenu
  CloseMenu
}

///|
priv struct State {
  collapsed : Bool
  preview_expanded : Bool
  menu_open : Bool
} derive(Eq)

///|
const PreviewLimit : Int = 5

///|
fn State::update(self : State, msg : Msg) -> State {
  match msg {
    ToggleDisclosure => { ..self, collapsed: !self.collapsed, menu_open: false }
    ShowMore => { ..self, preview_expanded: true }
    ToggleMenu => { ..self, menu_open: !self.menu_open }
    CloseMenu => { ..self, menu_open: false }
  }
}

///|
fn State::conversation_visible(
  self : State,
  index : Int,
  active : Bool,
) -> Bool {
  self.preview_expanded || index < PreviewLimit || active
}

///|
/// Capture-phase dismissal belongs to the project component whose menu is
/// open. It disappears with that keyed component branch.
priv struct Dismiss {
  key : String
  emit : @cmd.Emit[Unit]
}

///|
priv suberror DismissPayload {
  DismissPayload(String, @cmd.Emit[Unit])
}

///|
fn Dismiss::subscription(self : Dismiss) -> @sub.Sub {
  @sub.custom_sub(self.key, @sub.Global, DismissPayload(self.key, self.emit), (
    payload,
    scheduler,
  ) => Dismiss::load(payload, scheduler))
}

///|
fn Dismiss::load(
  payload : Error,
  scheduler : &@cmd.Scheduler,
) -> @sub.RunningSub? {
  guard payload is DismissPayload(key, emit) else { return None }
  let mut emit = emit
  let target = @dom.document().as_event_target()
  let listener : @dom.Listener = event => {
    if event.target().to_element() is Some(element) &&
      element.closest(".workspace-menu-button") is Some(button) &&
      button.get_attribute("data-sidebar-project-menu") is Some(trigger_key) &&
      trigger_key == key {
      // The owning trigger toggles this menu in its target-phase handler. A
      // different project's trigger is outside this component and therefore
      // dismisses this menu before opening its own.
      return
    }
    scheduler.add(emit(()))
  }
  target.add_event_listener_with_options("click", listener, capture=true)
  Some({
    unload: _ => {
      target.remove_event_listener_with_options("click", listener, capture=true)
    },
    update_tagger: next => {
      guard next is DismissPayload(next_key, next_emit) && next_key == key else {
        return
      }
      emit = next_emit
    },
  })
}

///|
fn Actions::conversation_component(
  self : Actions,
  _id : @conversation.Id,
  input : @rabbita.Val[@conversation.Input],
) -> @rabbita.Val[Array[@html.Html]] {
  @conversation.component(input, self.conversation)
}

///|
/// One keyed project component owns disclosure, compact-preview, and menu
/// state. Those values therefore cannot leak to an equal path rendered by a
/// different sidebar source.
pub fn component(
  input : @rabbita.Val[Input],
  actions : Actions,
) -> @rabbita.Val[Array[@html.Html]] {
  let (state, emit) = @rabbita.create_state_with_input(
    input~,
    init=(_, _) => {
      (
        { collapsed: false, preview_expanded: false, menu_open: false },
        @cmd.none,
      )
    },
    update=(state, _, msg, _) => (state.update(msg), @cmd.none),
    subscriptions=(state, input, emit) => {
      if state.menu_open {
        let dismiss : Dismiss = {
          key: input.id.subscription_key(),
          emit: emit.map((_ : Unit) => CloseMenu),
        }
        dismiss.subscription()
      } else {
        @sub.none
      }
    },
  )
  let conversation_inputs = input.map(input => {
    @vector.from_array(input.conversations)
  })
  let conversation_rows = conversation_inputs.assoc_by(
    (id, conversation) => actions.conversation_component(id, conversation),
    by=conversation => conversation.id(),
  )
  state.map3(input, conversation_rows, (state, input, conversation_rows) => {
    // The active project must reveal the newly selected conversation. Keep the
    // stored fold so leaving the project restores the user's previous choice.
    let collapsed = state.collapsed && !input.active
    let mut class = if collapsed {
      "workspace-row collapsible collapsed"
    } else {
      "workspace-row collapsible"
    }
    if input.active {
      class = class + " active"
    }
    if state.menu_open {
      class = class + " menu-open"
    }
    let row_children : Array[@html.Html] = [
      @html.button(
        class="workspace-disclosure",
        type_="button",
        title=input.title,
        on_click=emit(ToggleDisclosure),
        attrs=@html.Attrs::build().aria_expanded((!collapsed).to_string()),
        [
          @html.span(class="sidebar-icon", @icons.icon(@icons.icon_folder)),
          @html.span(class="sidebar-label", input.label),
        ],
      ),
    ]
    if input.managed {
      row_children.push(
        @html.button(
          class=if state.menu_open {
            "row-archive workspace-menu-button open"
          } else {
            "row-archive workspace-menu-button"
          },
          type_="button",
          title="More actions",
          attrs=@html.Attrs::build()
            .data_set("sidebar-project-menu", input.id.subscription_key())
            .on_click(event => {
              event.stop_propagation()
              emit(ToggleMenu)
            }),
          @icons.icon(@icons.icon_more),
        ),
      )
    }
    if input.can_start {
      row_children.push(
        @html.button(
          class="row-archive",
          type_="button",
          title="New conversation in this project",
          attrs=@html.Attrs::build().on_click(event => {
            event.stop_propagation()
            (actions.new_conversation)(input.id)
          }),
          @icons.icon(@icons.icon_add),
        ),
      )
    }
    if input.managed && state.menu_open {
      row_children.push(
        @html.div(class="workspace-menu", [
          @html.button(
            class="workspace-menu-item",
            type_="button",
            title="Defaults for new chats in this workspace",
            on_click=(actions.open_settings)(input.id),
            [
              @icons.icon(@icons.icon_settings_gear),
              @html.span("Workspace settings"),
            ],
          ),
          @html.button(
            class="workspace-menu-item",
            type_="button",
            title="Detach this project — its files and sessions stay",
            on_click=(actions.detach)(input.id),
            [@icons.icon(@icons.icon_close), @html.span("Detach project")],
          ),
        ]),
      )
    }
    let rows : Array[@html.Html] = [
      @html.div(class~, title=input.title, row_children),
    ]
    if collapsed {
      return rows
    }
    if conversation_rows.length() == 0 && input.empty_label is Some(label) {
      rows.push(
        @html.div(class="conversation-row placeholder nested", [
          @html.span(class="row-twisty spacer", ""),
          @html.span(class="sidebar-label", label),
        ]),
      )
      return rows
    }
    for index = 0; index < conversation_rows.length(); index = index + 1 {
      let group = conversation_rows[index]
      if state.conversation_visible(index, input.conversations[index].active) {
        for row in group {
          rows.push(row)
        }
      }
    }
    if !state.preview_expanded && conversation_rows.length() > PreviewLimit {
      rows.push(
        @html.button(
          class="project-show-more",
          type_="button",
          title="Show all \{conversation_rows.length()} chats in this project",
          on_click=emit(ShowMore),
          "Show more",
        ),
      )
    }
    rows
  })
}
