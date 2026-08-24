// A compact, state-free tab set for the large views inside one tool call.
//
// Native radio buttons own the selection. Rabbita therefore does not need to
// lift a transient viewing choice into the conversation model, while the
// browser still provides arrow-key navigation and a labelled control for each
// panel. All panels remain mounted; CSS lets only the selected one contribute
// height to the transcript.

///|
priv struct ToolCallTab {
  label : String
  body : @html.Html
}

///|
/// Render a radio-backed tab set. `key` is stable for the owning transcript
/// event, so a later render patches the same controls and preserves the tab
/// the reader selected. The first view is the useful default on first mount.
fn tool_call_tabs(key : String, tabs : Array[ToolCallTab]) -> @html.Html {
  let group = "tool-call-tabs-\{key}"
  let children : Array[@html.Html] = [
    @html.legend(class="visually-hidden", "Tool call details"),
  ]
  for index, tab in tabs {
    let id = "\{group}-\{index}"
    children.push(
      @html.input(
        input_type=Radio,
        name=group,
        id~,
        checked=index == 0,
        class="tool-call-tab-input",
      ),
    )
    children.push(@html.label(class="tool-call-tab-label", for_=id, tab.label))
  }
  children.push(
    @html.div(
      class="tool-call-tab-panels",
      [
        for tab in tabs => {
          @html.div(
            class="tool-call-tab-panel",
            attrs=@html.Attrs::build().role("region").aria_label(tab.label),
            [tab.body],
          )
        }
      ],
    ),
  )
  @html.fieldset(class="tool-call-tabs", children)
}
