// Decoding of the host's skill-market replies: the mooncakes.io catalog of
// installable skills and the contents of the engine's global skills
// library.

///|
/// One installable entry of the registry catalog, as the host reports it.
pub(all) struct MarketSkillItem {
  // Registry entry name, e.g. "moonbit-community/meta-skill".
  name : String
  module_name : String
  // Subpackage path relative to the module root; "" for a root skill.
  package_path : String
  version : String
  description : String
  author : String
  repository : String
}

///|
/// One entry of the local skills library.
pub(all) struct InstalledSkillItem {
  // The library entry — the key `skill_uninstall` takes.
  id : String
  // Display name from SKILL.md frontmatter.
  name : String
  description : String
  // `module@version[/package]` for registry installs; "" for a skill the
  // user wrote by hand (which the app never uninstalls).
  source : String
}

///|
/// The source label a catalog entry would carry once installed — the link
/// between a catalog row and the installed list.
pub fn market_source_label(item : MarketSkillItem) -> String {
  if item.package_path.is_empty() {
    "\{item.module_name}@\{item.version}"
  } else {
    "\{item.module_name}@\{item.version}/\{item.package_path}"
  }
}

///|
/// Map a decoded skill catalog into display rows. The shared protocol decoder
/// owns the wire shape and skips malformed rows before they reach this layer.
pub fn skills_catalog_from_reply(
  reply : @protocol.SkillsCatalogReply,
) -> Array[MarketSkillItem] {
  let items : Array[MarketSkillItem] = []
  for skill in reply.skills {
    items.push({
      name: if skill.name.trim().is_empty() {
        skill.module_name
      } else {
        skill.name
      },
      module_name: skill.module_name,
      package_path: skill.package_path,
      version: skill.version,
      description: skill.description,
      author: skill.author,
      repository: skill.repository,
    })
  }
  items
}

///|
/// Map a decoded installed-skill list into display rows.
pub fn installed_skills_from_reply(
  reply : @protocol.InstalledSkillsReply,
) -> Array[InstalledSkillItem] {
  let items : Array[InstalledSkillItem] = []
  for skill in reply.skills {
    items.push({
      id: skill.id,
      name: if skill.name.trim().is_empty() {
        skill.id
      } else {
        skill.name
      },
      description: skill.description,
      source: skill.source,
    })
  }
  items
}
