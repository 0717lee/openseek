// The row-target path joining the view uses, exercised directly: resource
// URI paths always use `/`, including Windows drive resources.

///|
fn test_resource(
  channel : @interop.ChannelId,
  path : String,
) -> @common.Uri raise {
  guard @resource.of_path(channel, path) is Some(resource) else {
    fail("test resource path was invalid: \{path}")
  }
  resource
}

///|
test "picker paths join with URI separators" {
  let channel = @interop.ChannelId::Local
  inspect(
    test_resource(channel, "/home/u").picker_child_path("proj"),
    content="/home/u/proj",
  )
  inspect(test_resource(channel, "/").picker_child_path("etc"), content="/etc")
  inspect(
    test_resource(channel, "/C:/code").picker_child_path("app"),
    content="/c:/code/app",
  )
}

///|
fn emit() -> @cmd.Emit[Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
/// Open the picker and land one listing at `location`.
fn opened(
  channel? : @interop.ChannelId = @interop.ChannelId::Local,
  location~ : Location,
  entries? : Array[String] = [],
) -> State raise {
  let (_, opening) = State::open(channel, emit())
  assert_true(opening.loading)
  let (_, loaded, _) = State::handle(
    opening,
    emit(),
    Msg::Loaded(channel~, location~, entries~, generation=1),
  )
  guard loaded is Some(picker) else { fail("picker closed by its own listing") }
  picker
}

///|
test "the picker opens loading and adopts the first listing" {
  let home = test_resource(@interop.ChannelId::Local, "/home/u")
  let (_, opening) = State::open(@interop.ChannelId::Local, emit())
  assert_true(opening.loading)
  assert_true(opening.location is None)
  let (_, loaded, _) = State::handle(
    opening,
    emit(),
    Msg::Loaded(
      channel=@interop.ChannelId::Local,
      location=Location::Directory(home),
      entries=["proj"],
      generation=1,
    ),
  )
  guard loaded is Some(picker) else { fail("picker closed by its own listing") }
  assert_true(
    picker.location is Some(Location::Directory(path)) && path.path == "/home/u",
  )
  inspect(picker.entries.length(), content="1")
  assert_true(!picker.loading)
}

///|
test "a listing for another channel or generation is dropped" {
  let opening = opened(
    location=Location::Directory(
      test_resource(@interop.ChannelId::Local, "/home/u"),
    ),
    entries=["proj"],
  )
  // A different device's listing cannot replace this picker's.
  let (_, foreign, _) = State::handle(
    opening,
    emit(),
    Msg::Loaded(
      channel=@interop.ChannelId::Remote("d_b"),
      location=Location::Directory(
        test_resource(@interop.ChannelId::Remote("d_b"), "/from-b"),
      ),
      entries=["wrong"],
      generation=1,
    ),
  )
  guard foreign is Some(picker) else {
    fail("current picker closed by a foreign listing")
  }
  assert_true(picker == opening)
  // A navigation bumps the generation and keeps the current listing; the
  // original listing's late reply cannot move the picker back.
  let (_, navigated, _) = State::handle(
    opening,
    emit(),
    Msg::Navigate("/home/u/proj"),
  )
  guard navigated is Some(browsing) else { fail("picker closed by navigation") }
  assert_true(browsing.loading)
  assert_true(
    browsing.location is Some(Location::Directory(path)) &&
    path.path == "/home/u",
  )
  let (_, stale, _) = State::handle(
    browsing,
    emit(),
    Msg::Loaded(
      channel=@interop.ChannelId::Local,
      location=Location::Directory(
        test_resource(@interop.ChannelId::Local, "/elsewhere"),
      ),
      entries=["wrong"],
      generation=1,
    ),
  )
  guard stale is Some(picker) else { fail("picker closed by a stale listing") }
  assert_true(picker == browsing)
}

///|
test "a failed navigation keeps the listing" {
  let opening = opened(
    location=Location::Directory(
      test_resource(@interop.ChannelId::Local, "/home/u"),
    ),
    entries=["proj"],
  )
  let (_, failed, outcome) = State::handle(
    opening,
    emit(),
    Msg::Failed(
      channel=@interop.ChannelId::Local,
      message="no such directory: /gone",
      generation=1,
    ),
  )
  guard failed is Some(picker) else {
    fail("picker closed by a failed navigation")
  }
  assert_true(
    picker.location is Some(Location::Directory(path)) && path.path == "/home/u",
  )
  inspect(picker.entries.length(), content="1")
  assert_true(!picker.loading)
  assert_true(
    outcome is Some(Outcome::Failed(message)) &&
    message == "no such directory: /gone",
  )
}

///|
test "confirm waits for an in-flight navigation" {
  let home = test_resource(@interop.ChannelId::Local, "/home/u")
  let opening = opened(location=Location::Directory(home))
  let (_, browsing, _) = State::handle(
    opening,
    emit(),
    Msg::Navigate("/home/u/other"),
  )
  guard browsing is Some(navigating) else {
    fail("picker closed by navigation")
  }
  // The shown listing is stale while the navigation is in flight: Enter
  // must not attach the previous directory.
  let (_, held, outcome) = State::handle(navigating, emit(), Msg::Confirm)
  assert_true(held is Some(_))
  assert_true(outcome is None)
}

///|
test "the Windows drive list shows its drives and refuses a confirm" {
  let opening = opened(location=Location::DriveList, entries=["C:", "D:"])
  assert_true(opening.location is Some(Location::DriveList))
  inspect(opening.entries.length(), content="2")
  assert_true(!opening.loading)
  let (_, held, outcome) = State::handle(opening, emit(), Msg::Confirm)
  assert_true(held is Some(_))
  assert_true(outcome is None)
}
