///|
fn apply_queue_event(items : Array[QueuedInput], event : QueueEvent) -> Unit {
  match event {
    Added(id~, content~) =>
      if !id.is_blank() &&
        !content.is_blank() &&
        !items.iter().any(item => item.id == id) {
        items.push({ id, content, })
      }
    Edited(id~, content~) =>
      for index, item in items {
        if item.id == id {
          items[index] = { id, content, }
          return
        }
      }
    Withdrawn(id~) | Steered(id~) | Promoted(id~) =>
      for index, item in items {
        if item.id == id {
          ignore(items.remove(index))
          return
        }
      }
  }
}

///|
/// Reconstruct the prompts still waiting after every append-only queue event.
pub fn Session::queued_inputs(self : Session) -> Array[QueuedInput] {
  let items : Array[QueuedInput] = []
  for event in self.events() {
    if event.item() is Queue(queue_event) {
      apply_queue_event(items, queue_event)
    }
  }
  items
}
