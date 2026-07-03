///|
fn prompt_entry(text : String) -> @history.Entry {
  let composer = @composer.Model::new("")
  @history.Entry::new(text, composer.mode())
}

///|
fn recalled_text(entry : @history.Entry?) -> String {
  match entry {
    Some(entry) => entry.text()
    None => "<none>"
  }
}

///|
test "history recalls entries and restores draft" {
  let history = @history.History::new()
  inspect(history.previous(prompt_entry("draft")) is None, content="true")
  history.push(prompt_entry("one"))
  history.push(prompt_entry("two"))
  let previous = history.previous(prompt_entry("draft"))
  inspect(recalled_text(previous), content="two")
  let previous = history.previous(prompt_entry("ignored"))
  inspect(recalled_text(previous), content="one")
  let previous = history.previous(prompt_entry("ignored"))
  inspect(recalled_text(previous), content="one")
  let next = history.next()
  inspect(recalled_text(next), content="two")
  let next = history.next()
  inspect(recalled_text(next), content="draft")
  inspect(history.next() is None, content="true")
}

///|
test "history skips empty and adjacent duplicate entries" {
  let history = @history.History::new()
  history.push(prompt_entry(""))
  inspect(history.previous(prompt_entry("draft")) is None, content="true")
  history.push(prompt_entry("same"))
  history.push(prompt_entry("same"))
  let previous = history.previous(prompt_entry("draft"))
  inspect(recalled_text(previous), content="same")
  let previous = history.previous(prompt_entry("ignored"))
  inspect(recalled_text(previous), content="same")
}

///|
test "history distinguishes shell and prompt entries" {
  let history = @history.History::new()
  history.push(prompt_entry("pwd"))
  let shell_composer = @composer.Model::new("")
  shell_composer.insert_user_text("!pwd")
  history.push(
    @history.Entry::new(shell_composer.text(), shell_composer.mode()),
  )
  let previous = history.previous(prompt_entry("draft"))
  assert_true(previous is Some(entry) && entry.mode().is_shell())
  let previous = history.previous(prompt_entry("ignored"))
  assert_true(previous is Some(entry) && entry.mode().is_input())
}
