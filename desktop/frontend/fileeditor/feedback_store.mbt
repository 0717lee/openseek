// The embedder-owned agent-feedback store behind the viewer's
// `AgentFeedbackHandle`. Since editor 0.1.1 the viewer's concrete
// `AgentFeedbackService` is internal to the editor module ("must not become
// a dependency of embedded clients"), so the panel keeps its own store here
// and hands the viewer a handle over it: the hover "+" glyph, the inline
// comment input, the bubbles, and the prev/next navigation all drive this
// store through that handle. The semantics mirror the editor's internal
// service (`internal/viewer/contrib/agent_feedback`): items keyed by
// `uri.to_string()`, `Emitter` change events, an `Accepted` birth firing
// `did_add_feedback` (the panel's composer-chip flow listens there), and a
// per-resource navigation anchor.

///|
/// The comment store shared by the panel (host-facing setters) and the
/// viewer's feedback contribution (through the handle built by
/// `agent_feedback_handle`).
priv struct AgentFeedbackStore {
  did_change_feedback : @common.Emitter[
    @agent_feedback_api.AgentFeedbackChangeEvent,
  ]
  did_change_navigation : @common.Emitter[@common.Uri]
  did_add_feedback : @common.Emitter[
    @agent_feedback_api.AgentFeedbackAddedEvent,
  ]
  items_by_resource : Map[String, Array[@agent_feedback_api.AgentFeedback]]
  // resource key → the item id (a `SessionEditorComment.id`) the prev/next
  // navigation is anchored on.
  navigation_anchor_by_resource : Map[String, String]
  // Resources whose editor offers the feedback affordances; the panel decides
  // which documents are commentable (real files, not notices).
  enabled_resources : Map[String, Bool]
  mut next_feedback_handle : Int
}

///|
/// Creates an empty feedback store.
fn AgentFeedbackStore::new() -> AgentFeedbackStore {
  {
    did_change_feedback: Emitter(),
    did_change_navigation: Emitter(),
    did_add_feedback: Emitter(),
    items_by_resource: Map([]),
    navigation_anchor_by_resource: Map([]),
    enabled_resources: Map([]),
    next_feedback_handle: 1,
  }
}

///|
/// Adapts this store to the capability handle the viewer consumes. The store
/// itself stays panel-owned; the handle borrows its methods.
fn AgentFeedbackStore::agent_feedback_handle(
  self : AgentFeedbackStore,
) -> @agent_feedback_api.AgentFeedbackHandle {
  @agent_feedback_api.AgentFeedbackHandle(
    on_did_change_feedback=listener => self.did_change_feedback.event(listener),
    on_did_change_navigation=listener => {
      self.did_change_navigation.event(listener)
    },
    is_feedback_enabled=resource => self.is_feedback_enabled(resource),
    get_feedback=resource => self.get_feedback(resource),
    get_navigation_bearing=(resource, item_ids) => {
      self.get_navigation_bearing(resource, item_ids)
    },
    add_feedback=(resource, range, text, kind, state) => {
      self.add_feedback(resource, range, text, kind?, state?)
    },
    mark_feedback_submitted=resource => self.mark_feedback_submitted(resource),
    remove_feedback=(resource, feedback_id) => {
      self.remove_feedback(resource, feedback_id)
    },
    accept_feedback=(resource, feedback_id) => {
      self.accept_feedback(resource, feedback_id)
    },
    set_navigation_anchor=(resource, item_id) => {
      self.set_navigation_anchor(resource, item_id)
    },
    update_feedback=(resource, feedback_id, new_text) => {
      self.update_feedback(resource, feedback_id, new_text)
    },
    add_reply=(resource, feedback_id, reply_text) => {
      self.add_reply(resource, feedback_id, reply_text)
    },
  )
}

// --- subscriptions -----------------------------------------------------------

///|
/// Fired when a new item enters the store in the `Accepted` state — for the
/// viewer's own UI that means the user just filed a comment, so this is the
/// panel's cue to turn it into a composer chip.
fn AgentFeedbackStore::on_did_add_feedback(
  self : AgentFeedbackStore,
  listener : (@agent_feedback_api.AgentFeedbackAddedEvent) -> Unit,
) -> @common.Disposable {
  self.did_add_feedback.event(listener)
}

// --- store internals -----------------------------------------------------------

///|
/// Re-broadcasts the feedback + navigation change events after a mutation.
fn AgentFeedbackStore::handle_items_changed(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Unit {
  self.did_change_feedback.fire({
    resource,
    feedback_items: self.get_feedback(resource),
  })
  self.did_change_navigation.fire(resource)
}

///|
/// The live per-resource item array, created on demand.
fn AgentFeedbackStore::items_for(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Array[@agent_feedback_api.AgentFeedback] {
  let key = resource.to_string()
  match self.items_by_resource.get(key) {
    Some(items) => items
    None => {
      let created : Array[@agent_feedback_api.AgentFeedback] = []
      self.items_by_resource.set(key, created)
      created
    }
  }
}

///|
/// Replaces an item known to exist in place, by id.
fn AgentFeedbackStore::replace_item(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  updated : @agent_feedback_api.AgentFeedback,
) -> Unit {
  let items = self.items_for(resource)
  match items.search_by(item => item.id == updated.id) {
    Some(index) => {
      items[index] = updated
      self.handle_items_changed(resource)
    }
    None => ()
  }
}

///|
fn AgentFeedbackStore::feedback_by_id(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  feedback_id : String,
) -> @agent_feedback_api.AgentFeedback? {
  let items = self.get_feedback(resource)
  match items.search_by(item => item.id == feedback_id) {
    Some(index) => Some(items[index])
    None => None
  }
}

///|
/// The prefixed id the editor widgets anchor navigation with.
fn to_session_editor_comment_id(source_id : String) -> String {
  "agentFeedback:" + source_id
}

// --- host-facing state ----------------------------------------------------------

///|
/// Turns the editor's feedback affordances (hover "+" glyph, inline input)
/// on or off for a resource. Fires the change event so the attached viewer
/// re-syncs.
fn AgentFeedbackStore::set_feedback_enabled(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  enabled : Bool,
) -> Unit {
  let key = resource.to_string()
  if self.is_feedback_enabled(resource) == enabled {
    return
  }
  if enabled {
    self.enabled_resources.set(key, true)
  } else {
    self.enabled_resources.remove(key)
  }
  self.handle_items_changed(resource)
}

///|
/// Whether the feedback affordances are active for a resource.
fn AgentFeedbackStore::is_feedback_enabled(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Bool {
  self.enabled_resources.get(resource.to_string()) is Some(enabled) && enabled
}

///|
/// All stored items for a resource. The array is live store state; mutations
/// go through the store methods so events fire.
fn AgentFeedbackStore::get_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Array[@agent_feedback_api.AgentFeedback] {
  match self.items_by_resource.get(resource.to_string()) {
    Some(items) => items
    None => []
  }
}

///|
/// Drops all items and the navigation anchor for a resource.
fn AgentFeedbackStore::clear_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Unit {
  let key = resource.to_string()
  self.navigation_anchor_by_resource.remove(key)
  self.items_by_resource.remove(key)
  self.handle_items_changed(resource)
}

// --- contribution-facing mutations ----------------------------------------------

///|
/// Stores a new item. `kind`/`state` default like upstream (user-authored,
/// immediately accepted); a system caller passes another `state` (the panel's
/// annotation re-show uses `Submitted`) so the item stays quiet. Only an
/// `Accepted` birth fires `did_add_feedback`.
fn AgentFeedbackStore::add_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  range : @common.Range,
  text : String,
  kind? : @agent_feedback_api.AgentFeedbackKind = UserReview,
  state? : @agent_feedback_api.AgentFeedbackState = Accepted,
) -> @agent_feedback_api.AgentFeedback {
  let feedback : @agent_feedback_api.AgentFeedback = {
    id: "viewer-feedback-" + self.next_feedback_handle.to_string(),
    text,
    resource,
    range,
    kind,
    replies: [],
    state,
  }
  self.next_feedback_handle += 1
  let items = self.items_for(resource)
  let has_existing_feedback_for_file = !items.is_empty()
  items.push(feedback)
  self.handle_items_changed(resource)
  if state == Accepted {
    self.did_add_feedback.fire({ feedback, has_existing_feedback_for_file })
  }
  feedback
}

///|
/// Transitions a `Created` item to `Accepted` so it becomes submittable.
fn AgentFeedbackStore::accept_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  feedback_id : String,
) -> Unit {
  guard self.feedback_by_id(resource, feedback_id) is Some(existing) else {
    return
  }
  guard existing.state == Created else { return }
  self.replace_item(resource, { ..existing, state: Accepted })
}

///|
/// Deletes an item; a navigation anchor pointing at it is cleared (the anchor
/// may hold either the raw id or the widget's prefixed comment id).
fn AgentFeedbackStore::remove_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  feedback_id : String,
) -> Unit {
  let key = resource.to_string()
  match self.navigation_anchor_by_resource.get(key) {
    Some(anchor) =>
      if anchor == feedback_id ||
        anchor == to_session_editor_comment_id(feedback_id) {
        self.navigation_anchor_by_resource.remove(key)
      }
    None => ()
  }
  let items = self.items_for(resource)
  match items.search_by(item => item.id == feedback_id) {
    Some(index) => {
      items.remove(index) |> ignore
      if items.is_empty() {
        self.items_by_resource.remove(key)
      }
      self.handle_items_changed(resource)
    }
    None => ()
  }
}

///|
/// Replaces an item's text.
fn AgentFeedbackStore::update_feedback(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  feedback_id : String,
  new_text : String,
) -> Unit {
  guard self.feedback_by_id(resource, feedback_id) is Some(existing) else {
    return
  }
  self.replace_item(resource, { ..existing, text: new_text })
}

///|
/// Appends a message to an item's thread.
fn AgentFeedbackStore::add_reply(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  feedback_id : String,
  reply_text : String,
) -> Unit {
  guard self.feedback_by_id(resource, feedback_id) is Some(existing) else {
    return
  }
  let replies = existing.replies.copy()
  replies.push(reply_text)
  self.replace_item(resource, { ..existing, replies, })
}

///|
/// Moves every `Accepted` item to `Submitted`. No-op when nothing is accepted.
fn AgentFeedbackStore::mark_feedback_submitted(
  self : AgentFeedbackStore,
  resource : @common.Uri,
) -> Unit {
  let items = self.items_for(resource)
  let mut submitted = false
  for index in 0..<items.length() {
    let item = items[index]
    guard item.state == Accepted else { continue }
    items[index] = { ..item, state: Submitted }
    submitted = true
  }
  guard submitted else { return }
  self.handle_items_changed(resource)
}

// --- navigation ------------------------------------------------------------------

///|
/// Pins prev/next navigation on an item (or clears it with `None`). Fires the
/// navigation event either way.
fn AgentFeedbackStore::set_navigation_anchor(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  item_id : String?,
) -> Unit {
  let key = resource.to_string()
  match item_id {
    Some(id) => self.navigation_anchor_by_resource.set(key, id)
    None => self.navigation_anchor_by_resource.remove(key)
  }
  self.did_change_navigation.fire(resource)
}

///|
/// Where the anchor sits in the supplied id order.
fn AgentFeedbackStore::get_navigation_bearing(
  self : AgentFeedbackStore,
  resource : @common.Uri,
  item_ids : Array[String],
) -> @agent_feedback_api.AgentFeedbackNavigationBearing {
  let active_idx = match
    self.navigation_anchor_by_resource.get(resource.to_string()) {
    Some(anchor) =>
      match item_ids.search_by(id => id == anchor) {
        Some(index) => index
        None => -1
      }
    None => -1
  }
  { active_idx, total_count: item_ids.length() }
}
