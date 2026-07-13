// Hand-written JSON codecs for workspace, skill catalog, self-update, and app
// launcher bridge messages. Optional fields are omitted on encode; collection
// replies keep a strict outer shape while skipping malformed rows.

///|
pub impl ToJson for WorkspacePayload with fn to_json(self) {
  @jsonx.object([("path", self.path.to_json())])
}

///|
pub impl FromJson for WorkspacePayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { path: @jsonx.required_string(fields, path, "path") }
}

///|
pub impl ToJson for WorkspacesReply with fn to_json(self) {
  @jsonx.object([("workspaces", self.workspaces.to_json())])
}

///|
pub impl FromJson for WorkspacesReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[String] = @jsonx.tolerant_rows(fields, path, "workspaces")
  { workspaces: decoded.filter(workspace => !workspace.is_empty()) }
}

///|
pub impl ToJson for PickWorkspaceReply with fn to_json(self) {
  let fields : Map[String, Json] = Map([])
  @jsonx.put_optional(fields, "path", self.path)
  Json::object(fields)
}

///|
pub impl FromJson for PickWorkspaceReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { path: @jsonx.optional(fields, path, "path") }
}

///|
pub impl ToJson for InstallSkillPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map::from_array([
    ("module_name", self.module_name.to_json()),
    ("version", self.version.to_json()),
  ])
  @jsonx.put_optional(fields, "package_path", self.package_path)
  Json::object(fields)
}

///|
pub impl FromJson for InstallSkillPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    module_name: @jsonx.required_string(fields, path, "module_name"),
    version: @jsonx.required_string(fields, path, "version"),
    package_path: @jsonx.optional(fields, path, "package_path"),
  }
}

///|
pub impl ToJson for UninstallSkillPayload with fn to_json(self) {
  @jsonx.object([("id", self.id.to_json())])
}

///|
pub impl FromJson for UninstallSkillPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { id: @jsonx.required_string(fields, path, "id") }
}

///|
pub impl ToJson for MarketSkill with fn to_json(self) {
  @jsonx.object([
    ("name", self.name.to_json()),
    ("module_name", self.module_name.to_json()),
    ("package_path", self.package_path.to_json()),
    ("version", self.version.to_json()),
    ("description", self.description.to_json()),
    ("author", self.author.to_json()),
    ("repository", self.repository.to_json()),
  ])
}

///|
pub impl FromJson for MarketSkill with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    name: @jsonx.required_string(fields, path, "name"),
    module_name: @jsonx.required_string(fields, path, "module_name"),
    package_path: @jsonx.required_string(fields, path, "package_path"),
    version: @jsonx.required_string(fields, path, "version"),
    description: @jsonx.required_string(fields, path, "description"),
    author: @jsonx.required_string(fields, path, "author"),
    repository: @jsonx.required_string(fields, path, "repository"),
  }
}

///|
pub impl ToJson for InstalledSkill with fn to_json(self) {
  @jsonx.object([
    ("id", self.id.to_json()),
    ("name", self.name.to_json()),
    ("description", self.description.to_json()),
    ("source", self.source.to_json()),
  ])
}

///|
pub impl FromJson for InstalledSkill with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    id: @jsonx.required_string(fields, path, "id"),
    name: @jsonx.required_string(fields, path, "name"),
    description: @jsonx.required_string(fields, path, "description"),
    source: @jsonx.required_string(fields, path, "source"),
  }
}

///|
pub impl ToJson for SkillsCatalogReply with fn to_json(self) {
  @jsonx.object([("skills", self.skills.to_json())])
}

///|
pub impl FromJson for SkillsCatalogReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[MarketSkill] = @jsonx.tolerant_rows(
    fields, path, "skills",
  )
  let skills = decoded.filter(skill => {
    !skill.module_name.is_empty() && !skill.version.is_empty()
  })
  { skills, }
}

///|
pub impl ToJson for InstalledSkillsReply with fn to_json(self) {
  @jsonx.object([("skills", self.skills.to_json())])
}

///|
pub impl FromJson for InstalledSkillsReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[InstalledSkill] = @jsonx.tolerant_rows(
    fields, path, "skills",
  )
  { skills: decoded.filter(skill => !skill.id.is_empty()) }
}

///|
pub impl ToJson for InstallSkillReply with fn to_json(self) {
  @jsonx.object([("installed", self.installed.to_json())])
}

///|
pub impl FromJson for InstallSkillReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { installed: @jsonx.required(fields, path, "installed") }
}

///|
pub impl ToJson for UninstallSkillReply with fn to_json(self) {
  @jsonx.object([("removed", self.removed.to_json())])
}

///|
pub impl FromJson for UninstallSkillReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { removed: @jsonx.required_bool(fields, path, "removed") }
}

///|
pub impl ToJson for OpenPathPayload with fn to_json(self) {
  @jsonx.object([
    ("session", self.session.to_json()),
    ("cwd", self.cwd.to_json()),
    ("path", self.path.to_json()),
  ])
}

///|
pub impl FromJson for OpenPathPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    cwd: @jsonx.required_string(fields, path, "cwd"),
    path: @jsonx.required_string(fields, path, "path"),
  }
}

///|
pub impl ToJson for OpenPathReply with fn to_json(self) {
  @jsonx.object([("opened", self.opened.to_json())])
}

///|
pub impl FromJson for OpenPathReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { opened: @jsonx.required_bool(fields, path, "opened") }
}

///|
pub impl ToJson for UpdateChannelPayload with fn to_json(self) {
  let fields : Map[String, Json] = Map([])
  @jsonx.put_optional(fields, "channel", self.channel)
  Json::object(fields)
}

///|
pub impl FromJson for UpdateChannelPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { channel: @jsonx.optional(fields, path, "channel") }
}

///|
pub impl ToJson for CheckUpdateReply with fn to_json(self) {
  match self {
    UpToDate => @jsonx.object([("kind", "up_to_date".to_json())])
    Available(version~, installable~) =>
      @jsonx.object([
        ("kind", "available".to_json()),
        ("version", version.to_json()),
        ("installable", installable.to_json()),
      ])
    Unreachable(reason~) =>
      @jsonx.object([
        ("kind", "unreachable".to_json()),
        ("reason", reason.to_json()),
      ])
    Malformed(reason~) =>
      @jsonx.object([
        ("kind", "malformed".to_json()),
        ("reason", reason.to_json()),
      ])
    Broken(version~, reason~) =>
      @jsonx.object([
        ("kind", "broken".to_json()),
        ("version", version.to_json()),
        ("reason", reason.to_json()),
      ])
  }
}

///|
pub impl FromJson for CheckUpdateReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  match @jsonx.required_string(fields, path, "kind") {
    "up_to_date" => UpToDate
    "available" =>
      Available(
        version=@jsonx.required_string(fields, path, "version"),
        installable=@jsonx.required_bool(fields, path, "installable"),
      )
    "unreachable" =>
      Unreachable(reason=@jsonx.required_string(fields, path, "reason"))
    "malformed" =>
      Malformed(reason=@jsonx.required_string(fields, path, "reason"))
    "broken" =>
      Broken(
        version=@jsonx.required_string(fields, path, "version"),
        reason=@jsonx.required_string(fields, path, "reason"),
      )
    kind => @jsonx.decode_error(path.add_key("kind"), "unknown kind: \{kind}")
  }
}

///|
pub impl ToJson for DownloadUpdateReply with fn to_json(self) {
  @jsonx.object([("version", self.version.to_json())])
}

///|
pub impl FromJson for DownloadUpdateReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { version: @jsonx.required_string(fields, path, "version") }
}

///|
pub impl ToJson for ApplyUpdateReply with fn to_json(self) {
  @jsonx.object([("applied", self.applied.to_json())])
}

///|
pub impl FromJson for ApplyUpdateReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { applied: @jsonx.required_bool(fields, path, "applied") }
}

///|
pub impl ToJson for WorkspaceBranchPayload with fn to_json(self) {
  @jsonx.object([
    ("session", self.session.to_json()),
    ("cwd", self.cwd.to_json()),
  ])
}

///|
pub impl FromJson for WorkspaceBranchPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    cwd: @jsonx.required_string(fields, path, "cwd"),
  }
}

///|
pub impl ToJson for WorkspaceBranchReply with fn to_json(self) {
  @jsonx.object([("branch", self.branch.to_json())])
}

///|
pub impl FromJson for WorkspaceBranchReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { branch: @jsonx.required_string(fields, path, "branch") }
}

///|
pub impl ToJson for ArchiveSessionPayload with fn to_json(self) {
  @jsonx.object([("session", self.session.to_json())])
}

///|
pub impl FromJson for ArchiveSessionPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { session: @jsonx.required_string(fields, path, "session") }
}

///|
pub impl ToJson for AppEntry with fn to_json(self) {
  @jsonx.object([
    ("id", self.id.to_json()),
    ("name", self.name.to_json()),
    ("icon", self.icon.to_json()),
  ])
}

///|
pub impl FromJson for AppEntry with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    id: @jsonx.required_string(fields, path, "id"),
    name: @jsonx.required_string(fields, path, "name"),
    icon: @jsonx.required_string(fields, path, "icon"),
  }
}

///|
pub impl ToJson for ListAppsReply with fn to_json(self) {
  @jsonx.object([("apps", self.apps.to_json())])
}

///|
pub impl FromJson for ListAppsReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  let decoded : Array[AppEntry] = @jsonx.tolerant_rows(fields, path, "apps")
  { apps: decoded.filter(app => !app.id.is_empty()) }
}

///|
pub impl ToJson for LaunchAppPayload with fn to_json(self) {
  @jsonx.object([
    ("session", self.session.to_json()),
    ("cwd", self.cwd.to_json()),
    ("app", self.app.to_json()),
  ])
}

///|
pub impl FromJson for LaunchAppPayload with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  {
    session: @jsonx.required_string(fields, path, "session"),
    cwd: @jsonx.required_string(fields, path, "cwd"),
    app: @jsonx.required_string(fields, path, "app"),
  }
}

///|
pub impl ToJson for LaunchAppReply with fn to_json(self) {
  @jsonx.object([("launched", self.launched.to_json())])
}

///|
pub impl FromJson for LaunchAppReply with fn from_json(json, path) {
  let fields = @jsonx.expect_object(json, path)
  { launched: @jsonx.required_bool(fields, path, "launched") }
}
