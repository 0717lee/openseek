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
