// The unified model chip: one composer control whose grouped menu spans every
// available agent. Picking an option decides an (agent, model) pair — the
// state is two facts even though the control is one select. A conversation's agent is
// fixed by its first turn; only a composing conversation (an OpenSeek chat
// with nothing sent, or a Codex draft with no app-server thread) may still be
// handed to another agent, so only those chips offer cross-agent groups. dsh
// cannot list models before a session exists, so its entry creates that
// session first; the dsh composer then renders the authoritative catalog.

///|
/// Which agent runs a conversation. Persisted as the default for the next
/// "New chat"; a conversation that has begun never changes agents.
priv enum AgentChoice {
  OpenSeekAgent
  CodexAgent
  DshAgent
} derive(Eq)

///|
fn AgentChoice::wire(self : AgentChoice) -> String {
  match self {
    OpenSeekAgent => "openseek"
    CodexAgent => "codex"
    DshAgent => "dsh"
  }
}

///|
fn AgentChoice::parse(value : String) -> AgentChoice? {
  match value.trim().to_owned() {
    "openseek" => Some(OpenSeekAgent)
    "codex" => Some(CodexAgent)
    "dsh" => Some(DshAgent)
    _ => None
  }
}

///|
/// One pick in the unified model chip, encoded into the native select's
/// option value. Codex ids live in their own namespace so one can never be
/// mistaken for an OpenSeek tier — `EngineModel::parse` adopts any unknown
/// string as a custom tier, which is exactly the silent misroute the
/// prefixes exist to prevent.
priv enum ModelChoice {
  OpenSeekModel(EngineModel)
  CodexModel(String)
  // The Codex group's only row while no model catalog is usable. Picking it
  // is a request to open the Codex page, where sign-in and connection state
  // live; it never changes the selected model.
  CodexUnavailablePick
  // dsh's model catalog belongs to one concrete session. A ready pick creates
  // that session in the current local project; the placeholder opens the dsh
  // page so its connection problem can be resolved without pretending that a
  // model is already selectable.
  DshNewConversation
  DshUnavailablePick
}

///|
const OpenSeekChoicePrefix = "openseek:"

///|
const CodexChoicePrefix = "codex:"

///|
const CodexUnavailableChoiceWire = "codex.unavailable"

///|
const DshNewConversationWire = "dsh:new"

///|
const DshUnavailableChoiceWire = "dsh.unavailable"

///|
fn ModelChoice::wire(self : ModelChoice) -> String {
  match self {
    OpenSeekModel(model) => OpenSeekChoicePrefix + model.wire()
    CodexModel(id) => CodexChoicePrefix + id
    CodexUnavailablePick => CodexUnavailableChoiceWire
    DshNewConversation => DshNewConversationWire
    DshUnavailablePick => DshUnavailableChoiceWire
  }
}

///|
fn ModelChoice::parse(value : String) -> ModelChoice? {
  if value == CodexUnavailableChoiceWire {
    return Some(CodexUnavailablePick)
  }
  if value == DshNewConversationWire {
    return Some(DshNewConversation)
  }
  if value == DshUnavailableChoiceWire {
    return Some(DshUnavailablePick)
  }
  if value.has_prefix(OpenSeekChoicePrefix) {
    let rest = value.view(start_offset=OpenSeekChoicePrefix.length()).to_owned()
    return EngineModel::parse(rest).map(model => OpenSeekModel(model))
  }
  if value.has_prefix(CodexChoicePrefix) {
    let id = value.view(start_offset=CodexChoicePrefix.length()).to_owned()
    if !id.trim().is_empty() {
      return Some(CodexModel(id))
    }
  }
  None
}

///|
test "model choices round-trip and the agent namespaces stay disjoint" {
  assert_true(
    ModelChoice::parse("openseek:deepseek-v4-pro") is Some(OpenSeekModel(High)),
  )
  // A tier's wire name inside the Codex namespace is a Codex id, never a
  // tier — and a bare wire name belongs to neither agent.
  assert_true(
    ModelChoice::parse("codex:deepseek-v4-pro")
    is Some(CodexModel("deepseek-v4-pro")),
  )
  assert_true(ModelChoice::parse("deepseek-v4-pro") is None)
  assert_true(
    ModelChoice::parse("codex.unavailable") is Some(CodexUnavailablePick),
  )
  assert_true(ModelChoice::parse("dsh:new") is Some(DshNewConversation))
  assert_true(ModelChoice::parse("dsh.unavailable") is Some(DshUnavailablePick))
  assert_true(ModelChoice::parse("codex:") is None)
  assert_true(ModelChoice::parse("openseek:") is None)
  inspect(
    ModelChoice::OpenSeekModel(Low).wire(),
    content="openseek:deepseek-v4-flash",
  )
  inspect(ModelChoice::CodexModel("gpt-5.4").wire(), content="codex:gpt-5.4")
  assert_true(
    ModelChoice::parse(ModelChoice::CodexModel("gpt-5.4").wire())
    is Some(CodexModel("gpt-5.4")),
  )
}

///|
test "agent choices round-trip their wire names" {
  assert_true(AgentChoice::parse("openseek") is Some(OpenSeekAgent))
  assert_true(AgentChoice::parse("codex") is Some(CodexAgent))
  assert_true(AgentChoice::parse("dsh") is Some(DshAgent))
  assert_true(AgentChoice::parse("") is None)
  assert_true(AgentChoice::parse("claude") is None)
  inspect(AgentChoice::OpenSeekAgent.wire(), content="openseek")
  inspect(AgentChoice::CodexAgent.wire(), content="codex")
  inspect(AgentChoice::DshAgent.wire(), content="dsh")
}

///|
test "the dsh group stays an honest doorway until dsh can create a session" {
  let group = { ..test_model(), is_desktop: true }.dsh_model_group()
  assert_eq(group.label, "DeepSeek Harness")
  assert_eq(group.options.length(), 1)
  assert_eq(group.options[0].value, DshUnavailableChoiceWire)
  assert_eq(group.options[0].label, "Open DeepSeek Harness")
}

///|
/// The OpenSeek group always offers the two service tiers; a conversation
/// running an unknown wire name keeps it visible, same as the old selector.
fn openseek_model_group(selected : EngineModel) -> @composer.ModelGroup {
  let options : Array[@composer.ModelOption] = [
    {
      value: ModelChoice::OpenSeekModel(High).wire(),
      label: EngineModel::High.label(),
    },
    {
      value: ModelChoice::OpenSeekModel(Low).wire(),
      label: EngineModel::Low.label(),
    },
  ]
  if selected is Other(name) {
    options.push({
      value: ModelChoice::OpenSeekModel(selected).wire(),
      label: name,
    })
  }
  { label: "OpenSeek", options }
}

///|
/// Codex's group mirrors the fetched catalog; without one it offers the one
/// row that leads to the Codex page instead of hiding the agent entirely.
fn Model::codex_model_group(self : Model) -> @composer.ModelGroup {
  match self.codex.model_listing() {
    CodexModels(options, selected=_) => {
      let prefixed : Array[@composer.ModelOption] = []
      for option in options {
        prefixed.push({
          value: ModelChoice::CodexModel(option.value).wire(),
          label: option.label,
        })
      }
      { label: "Codex", options: prefixed }
    }
    CodexModelsUnavailable(label) =>
      {
        label: "Codex",
        options: [{ value: CodexUnavailableChoiceWire, label }],
      }
  }
}

///|
/// dsh cannot answer `session.models` until a session exists. Keep that fact
/// explicit in the unified menu: a ready row creates a conversation, while an
/// unavailable row only opens the dsh page and asks its actor to reconnect.
fn Model::dsh_model_group(self : Model) -> @composer.ModelGroup {
  if self.dsh.can_create() {
    {
      label: "DeepSeek Harness",
      options: [
        { value: DshNewConversationWire, label: "New DeepSeek Harness chat" },
      ],
    }
  } else {
    {
      label: "DeepSeek Harness",
      options: [
        { value: DshUnavailableChoiceWire, label: "Open DeepSeek Harness" },
      ],
    }
  }
}

///|
/// The unified model chip on an OpenSeek conversation. A conversation that
/// has not begun may still be handed to another available local agent; once
/// the transcript exists the agent is fixed and the menu narrows to
/// OpenSeek's tiers.
fn Model::openseek_model_chip(
  self : Model,
  dispatch : @cmd.Emit[Msg],
  conv : Conversation,
) -> @html.Html {
  let groups : Array[@composer.ModelGroup] = [
    openseek_model_group(conv.engine_model),
  ]
  if self.composing_new_chat() {
    groups.push(self.codex_model_group())
    // dsh lives in this native process. A remote or browser conversation has
    // no local project authority to hand to it, so do not advertise a switch
    // whose workspace could not be preserved.
    if self.is_desktop && self.focused == @interop.ChannelId::Local {
      groups.push(self.dsh_model_group())
    }
  }
  @composer.ModelSelect::{
    groups,
    selected: ModelChoice::OpenSeekModel(conv.engine_model).wire(),
    disabled: false,
    change: dispatch.map(value => ModelPicked(value)),
    title: "Model: \{conv.engine_model.label()}",
  }.render()
}

///|
/// OpenSeek's reasoning chip shares the same control as Codex but offers only
/// the values its DeepSeek request format defines. An unknown model may be a
/// provider such as Kimi, so hiding the chip there is safer than sending a
/// setting that provider deliberately ignores.
fn Model::openseek_reasoning_chip(
  self : Model,
  dispatch : @cmd.Emit[Msg],
  conv : Conversation,
) -> @html.Html? {
  guard conv.engine_model.supports_reasoning() else { return None }
  let options : Array[@composer.ModelOption] = [
    { value: ReasoningOff.wire(), label: "Reasoning · Off" },
    { value: ReasoningHigh.wire(), label: "Reasoning · High" },
    { value: ReasoningMax.wire(), label: "Reasoning · Max" },
  ]
  Some(
    @composer.ReasoningSelect::{
      options,
      selected: self.openseek_reasoning.wire(),
      disabled: false,
      change: dispatch.map(value => OpenSeekEffortPicked(value)),
      title: "Reasoning effort: \{self.openseek_reasoning.label()}",
    }.render(),
  )
}

///|
/// The unified model chip on the Codex page. A composing draft may still be
/// handed to OpenSeek or local dsh; a stored thread's transcript is Codex's
/// alone, so its menu narrows to Codex models.
fn Model::codex_model_chip(
  self : Model,
  dispatch : @cmd.Emit[Msg],
) -> @html.Html {
  let groups : Array[@composer.ModelGroup] = []
  if self.codex.composing_draft() {
    groups.push(openseek_model_group(self.default_model))
  }
  groups.push(self.codex_model_group())
  if self.codex.composing_draft() &&
    self.is_desktop &&
    self.focused == @interop.ChannelId::Local {
    groups.push(self.dsh_model_group())
  }
  let selected = match self.codex.model_listing() {
    CodexModels(_, selected~) => ModelChoice::CodexModel(selected).wire()
    CodexModelsUnavailable(_) => CodexUnavailableChoiceWire
  }
  @composer.ModelSelect::{
    groups,
    selected,
    disabled: false,
    change: dispatch.map(value => ModelPicked(value)),
    title: "Codex model",
  }.render()
}
