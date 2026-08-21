// The picker's contract as the shell sees it: what it reports, what it
// accepts, and what makes it close. Runs are built by driving the same
// entry points `frontend` drives — `State::open` and `State::handle` — so
// nothing here reads inside the package beyond its public API.

///|
fn emit() -> @cmd.Emit[@project_picker.Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
/// A resource fixture with the same validation as protocol input, mirroring
/// the shell's test helper for tests that live outside it.
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
/// Open the picker and land one listing at `location`.
fn opened(
  channel? : @interop.ChannelId = @interop.ChannelId::Local,
  location~ : @project_picker.Location,
  entries? : Array[String] = [],
) -> @project_picker.State raise {
  let (_, opening) = @project_picker.State::open(channel, emit())
  assert_true(opening.loading)
  let (_, loaded, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Loaded(channel~, location~, entries~, generation=1),
  )
  guard loaded is Some(picker) else { fail("picker closed by its own listing") }
  picker
}

///|
test "the picker opens loading and adopts the first listing" {
  let home = test_resource(@interop.ChannelId::Local, "/home/u")
  let (_, opening) = @project_picker.State::open(
    @interop.ChannelId::Local,
    emit(),
  )
  assert_true(opening.loading)
  assert_true(opening.location is None)
  let (_, loaded, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Loaded(
      channel=@interop.ChannelId::Local,
      location=@project_picker.Location::Directory(home),
      entries=["proj"],
      generation=1,
    ),
  )
  guard loaded is Some(picker) else { fail("picker closed by its own listing") }
  assert_true(
    picker.location is Some(@project_picker.Location::Directory(path)) &&
    path.path == "/home/u",
  )
  inspect(picker.entries.length(), content="1")
  assert_true(!picker.loading)
}

///|
test "a listing for another channel or generation is dropped" {
  let opening = opened(
    location=@project_picker.Location::Directory(
      test_resource(@interop.ChannelId::Local, "/home/u"),
    ),
    entries=["proj"],
  )
  // A different device's listing cannot replace this picker's.
  let (_, foreign, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Loaded(
      channel=@interop.ChannelId::Remote("d_b"),
      location=@project_picker.Location::Directory(
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
  // A stale generation cannot move the picker back after a navigation
  // bumped it.
  let (_, navigated, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Navigate("/home/u/proj"),
  )
  guard navigated is Some(browsing) else { fail("picker closed by navigation") }
  assert_true(browsing.loading)
  // A navigation keeps the previous listing; only the reply may move it.
  assert_true(
    browsing.location is Some(@project_picker.Location::Directory(path)) &&
    path.path == "/home/u",
  )
  let (_, stale, _) = @project_picker.State::handle(
    browsing,
    emit(),
    @project_picker.Msg::Loaded(
      channel=@interop.ChannelId::Local,
      location=@project_picker.Location::Directory(
        test_resource(@interop.ChannelId::Local, "/home/u"),
      ),
      entries=["proj"],
      generation=1,
    ),
  )
  guard stale is Some(picker) else { fail("picker closed by a stale listing") }
  assert_true(picker == browsing)
}

///|
test "a failed navigation keeps the listing and reports the failure" {
  let opening = opened(
    location=@project_picker.Location::Directory(
      test_resource(@interop.ChannelId::Local, "/home/u"),
    ),
    entries=["proj"],
  )
  let (_, failed, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Failed(
      channel=@interop.ChannelId::Local,
      message="no such directory: /gone",
      generation=1,
    ),
  )
  guard failed is Some(picker) else {
    fail("picker closed by a failed navigation")
  }
  assert_true(
    picker.location is Some(@project_picker.Location::Directory(path)) &&
    path.path == "/home/u",
  )
  inspect(picker.entries.length(), content="1")
  assert_true(!picker.loading)
  // A failure answering a superseded navigation stays silent.
  let (_, stale, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Failed(
      channel=@interop.ChannelId::Local,
      message="stale",
      generation=99,
    ),
  )
  guard stale is Some(picker) else { fail("picker closed by a stale failure") }
  assert_true(picker == opening)
}

///|
test "confirm picks the browsed directory and closes the picker" {
  let home = test_resource(@interop.ChannelId::Local, "/home/u/proj")
  let opening = opened(location=@project_picker.Location::Directory(home))
  let (_, closed, outcome) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Confirm,
  )
  assert_true(closed is None)
  assert_true(
    outcome is Some(@project_picker.Outcome::Picked(path)) && path == home,
  )
  // Confirming before anything was browsed has nothing to register and
  // keeps the picker open.
  let (_, empty) = @project_picker.State::open(
    @interop.ChannelId::Local,
    emit(),
  )
  let (_, early, outcome) = @project_picker.State::handle(
    empty,
    emit(),
    @project_picker.Msg::Confirm,
  )
  assert_true(early is Some(_))
  assert_true(outcome is None)
  // An in-flight navigation makes the shown listing stale: Enter must not
  // attach the previous directory.
  let (_, browsing, _) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Navigate("/home/u/other"),
  )
  guard browsing is Some(navigating) else {
    fail("picker closed by navigation")
  }
  let (_, held, outcome) = @project_picker.State::handle(
    navigating,
    emit(),
    @project_picker.Msg::Confirm,
  )
  assert_true(held is Some(_))
  assert_true(outcome is None)
}

///|
test "the Windows drive list shows its drives and refuses a confirm" {
  let opening = opened(location=@project_picker.Location::DriveList, entries=[
    "C:", "D:",
  ])
  assert_true(opening.location is Some(@project_picker.Location::DriveList))
  inspect(opening.entries.length(), content="2")
  assert_true(!opening.loading)
  // The drive list is not a directory: Enter and "Add" have nothing to
  // register, so the picker stays open with nothing picked.
  let (_, held, outcome) = @project_picker.State::handle(
    opening,
    emit(),
    @project_picker.Msg::Confirm,
  )
  assert_true(held is Some(_))
  assert_true(outcome is None)
}

///|
/// Resource paths are the picker's wire spelling: POSIX paths stay as they
/// are, and Windows drive roots keep the trailing slash that makes them
/// child-joinable ("/C:/").
test "picker paths keep their URI spelling" {
  let channel = @interop.ChannelId::Local
  assert_eq(test_resource(channel, "/home/u").path, "/home/u")
  assert_eq(test_resource(channel, "/etc").path, "/etc")
  // Resource URIs normalize the drive letter's case.
  assert_eq(test_resource(channel, "/C:/").path, "/c:/")
  assert_eq(test_resource(channel, "/C:/code").path, "/c:/code")
}
