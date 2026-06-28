///|
/// Discover the skills the engine advertises to the model, the SAME way the
/// engine does (a mirror of `skills_prompt_section_for_cwd` in `cmd/openseek`):
/// the workspace library under `<workspace>/.openseek/skills` merged over the
/// user-level library (default `$HOME/.openseek/skills`, workspace shadows
/// global). Kept in sync with the engine so the `/skills` picker never lists a
/// skill the model was never told about. The TUI passes no custom
/// `--global-skills-dir` to the engine (see `engine_extra_env`), so the engine
/// always uses the default resolved here.
async fn discover_picker_skills(
  workspace_root : String,
) -> Array[@completion.CompletionItem] {
  let global_skills = match default_global_skills_dir() {
    Some(dir) => @agent_skill.discover_skills(dir)
    None => []
  }
  let workspace_skills = @agent_skill.discover_skills(
    @workspace_path.resolve(workspace_root, ".openseek/skills"),
  )
  let merged = @agent_skill.merge_skills(global_skills, overrides=workspace_skills)
  merged.map(skill => @completion.CompletionItem::new(
    label=skill.name(),
    insert_text="Use the \"\{skill.name()}\" skill. ",
    description=skill.description(),
  ))
}

///|
/// `<home>/.openseek/skills` when `home` is set and non-blank, else `None`.
fn home_skills_dir(value : String?) -> String? {
  if value is Some(home) && home.trim() != "" {
    Some("\{home.trim()}/.openseek/skills")
  } else {
    None
  }
}

///|
/// The default user-level skills directory, mirroring the engine's
/// `default_global_skills_dir`: `$HOME/.openseek/skills`.
#cfg(not(platform="windows"))
fn default_global_skills_dir() -> String? {
  home_skills_dir(@env.get_env_var("HOME"))
}

///|
/// The default user-level skills directory on Windows: `%USERPROFILE%`, falling
/// back to `%HOME%`.
#cfg(platform="windows")
fn default_global_skills_dir() -> String? {
  match home_skills_dir(@env.get_env_var("USERPROFILE")) {
    Some(dir) => Some(dir)
    None => home_skills_dir(@env.get_env_var("HOME"))
  }
}
