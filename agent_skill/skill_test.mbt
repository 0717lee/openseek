///|
async fn write_skill(path : String, text : String) -> Unit {
  @fs.write_file(path, text, create_mode=CreateOrTruncate)
}

///|
async test "discovery reads flat files and SKILL.md directories, sorted" {
  let dir = @fs.tmpdir(prefix="openseek-skills-")
  write_skill(
    dir + "/zeta.md",
    (
      #|---
      #|name: zeta-protocol
      #|description: How to zeta.
      #|---
      #|Body text.
    ),
  )
  @fs.mkdir(dir + "/alpha", recursive=true)
  write_skill(
    dir + "/alpha/SKILL.md",
    (
      #|---
      #|description: Alpha steps.
      #|---
      #|Steps.
    ),
  )
  // No frontmatter at all: still listed under its file stem.
  write_skill(dir + "/bare.md", "Just instructions, no header.")
  // A non-skill directory and a stray file are ignored.
  @fs.mkdir(dir + "/not-a-skill", recursive=true)
  write_skill(dir + "/notes.txt", "not markdown")
  let skills = @agent_skill.discover_skills(dir)
  assert_eq(skills.length(), 3)
  // Sorted by name (String order is length-first, so "bare" precedes
  // "alpha"); the SKILL.md layout names itself after its directory.
  assert_eq(skills[0].name(), "bare")
  assert_eq(skills[0].description(), "")
  assert_eq(skills[1].name(), "alpha")
  assert_eq(skills[1].description(), "Alpha steps.")
  assert_eq(skills[1].path(), dir + "/alpha/SKILL.md")
  assert_eq(skills[2].name(), "zeta-protocol")
  assert_eq(skills[2].description(), "How to zeta.")
  @fs.rmdir(dir, recursive=true)
}

///|
async test "a malformed frontmatter never hides the skill" {
  let dir = @fs.tmpdir(prefix="openseek-skills-malformed-")
  // Opening --- with no closing fence: keys still parse until EOF.
  write_skill(
    dir + "/open.md",
    (
      #|---
      #|name: still-found
      #|no colon line
    ),
  )
  let skills = @agent_skill.discover_skills(dir)
  assert_eq(skills.length(), 1)
  assert_eq(skills[0].name(), "still-found")
  @fs.rmdir(dir, recursive=true)
}

///|
async test "a missing skills directory is an empty library" {
  let skills = @agent_skill.discover_skills("/nonexistent/openseek-skills")
  assert_eq(skills.length(), 0)
  assert_true(@agent_skill.skills_prompt_section(skills) is None)
}

///|
async test "the prompt section lists usage, names, and paths" {
  let dir = @fs.tmpdir(prefix="openseek-skills-prompt-")
  write_skill(
    dir + "/release.md",
    (
      #|---
      #|name: release
      #|description: Cut a release of this project.
      #|---
      #|1. bump version
    ),
  )
  let skills = @agent_skill.discover_skills(dir)
  guard @agent_skill.skills_prompt_section(skills) is Some(section) else {
    fail("expected a section")
  }
  assert_true(section.contains("## Skills"))
  assert_true(section.contains("read its file with the read tool"))
  assert_true(
    section.contains(
      "- release — Cut a release of this project. (file: \{dir}/release.md)",
    ),
  )
  @fs.rmdir(dir, recursive=true)
}
