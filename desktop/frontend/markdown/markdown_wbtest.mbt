// Structural tests for the markdown renderer. Rabbita's Html is opaque and
// 0.15.1 removed the js-target `render_to_string`, so the tests assert on the
// number of block-level nodes a document produces and on the pure decisions
// behind the markup: which fence becomes a diagram, and what a destination is
// allowed to open.

///|
test "markdown renders block structure" {
  inspect(markdown_nodes("").length(), content="0")
  inspect(markdown_nodes("just a paragraph").length(), content="1")
  inspect(markdown_nodes("# Title\n\nbody text").length(), content="2")
  inspect(markdown_nodes("- one\n- two\n- three").length(), content="1")
  inspect(
    markdown_nodes("para\n\n```moonbit\nfn main {}\n```\n\n---").length(),
    content="3",
  )
  inspect(markdown_nodes("> quoted\n> text").length(), content="1")
  inspect(
    markdown_nodes("| a | b |\n| - | - |\n| 1 | 2 |").length(),
    content="1",
  )
}

///|
test "exact UML fences render the shared Viewer SVG" {
  let source = "@startuml\nparticipant Alice\nAlice -> Bob : hello\n@enduml"
  for language in ["uml", "plantuml"] {
    guard diagram_svg(language, source) is Some(svg) else {
      fail("expected \{language} to render a diagram")
    }
    assert_true(svg.contains("<svg"))
  }
  // Only those two fences: any other language keeps its code block, even when
  // the body would have drawn.
  assert_true(diagram_svg("moonbit", source) is None)
}

///|
test "invalid UML and Mermaid keep their code-block fallback" {
  // A body the shared renderer rejects falls back rather than drawing an
  // empty diagram.
  assert_true(diagram_svg("uml", "@startuml\n@enduml") is None)
  assert_true(diagram_svg("mermaid", "A --> B") is None)
}

///|
test "markdown survives streaming-truncated input" {
  // An unterminated fence parses as *something* renderable rather than
  // aborting — the streaming view re-parses partial text on every delta.
  inspect(markdown_nodes("intro\n\n```moonbit\nfn ma").length(), content="2")
  inspect(markdown_nodes("broken **emphasi").length(), content="1")
  inspect(markdown_nodes("dangling [link](htt").length(), content="1")
}

///|
test "raw html stays text instead of markup" {
  // One pre.raw-html block; the structure proves the branch is taken and the
  // payload is routed through a text node, never through innerHTML.
  inspect(markdown_nodes("<script>alert(1)</script>").length(), content="1")
}

///|
test "local raster images wait for the transcript host loader" {
  // A model-authored destination reaches the host as a decoded path; the host
  // verifies the byte signature before it loads one.
  assert_eq(
    local_image_path("../../Downloads/meetup.png"),
    Some("../../Downloads/meetup.png"),
  )
  assert_eq(local_image_path("My%20Plot.png"), Some("My Plot.png"))
  assert_eq(
    local_image_path("/Users/me/My Image.JPG"),
    Some("/Users/me/My Image.JPG"),
  )
  assert_eq(
    local_image_path("file:///Users/me/My%20Image.webp"),
    Some("/Users/me/My Image.webp"),
  )
  // SVG and web URLs stay under the renderer's existing destination policy;
  // only byte-signature-checked raster files enter the host read path.
  assert_eq(local_image_path("https://example.com/image.png"), None)
  assert_eq(local_image_path("./diagram.svg"), None)
}

///|
test "bare web URLs in prose end where the sentence resumes" {
  // Prose punctuation is not part of the URL, while a balanced closer is.
  assert_eq(
    trim_bare_url("https://example.com/docs,"),
    ("https://example.com/docs", ","),
  )
  assert_eq(
    trim_bare_url("http://localhost:8080/a_(b)."),
    ("http://localhost:8080/a_(b)", "."),
  )
  assert_eq(
    trim_bare_url("https://example.com/wiki/Foo_(bar))"),
    ("https://example.com/wiki/Foo_(bar)", ")"),
  )
  // One anchor per URL, with the prose before it, the punctuation it shed,
  // and the rest of the sentence each kept as their own text nodes.
  inspect(
    linkified_text_nodes("See https://example.com/docs, then done.").length(),
    content="4",
  )
}

///|
test "a scheme without an authority remains text" {
  inspect(linkified_text_nodes("streaming https://").length(), content="1")
  // The URL-only renderer's contract: prose may only link a destination that
  // has a non-empty authority, so a file-shaped scheme stays inert.
  assert_false(has_web_authority("https://"))
  assert_false(has_web_authority("https:///docs"))
  assert_true(has_web_authority("https://example.com/docs"))
  assert_true(has_web_authority("http://localhost:8080/a"))
}

///|
test "explicit destinations decide what a link may open" {
  // A slash-bearing target may be a file or a directory; the host decides
  // from the filesystem when clicked.
  assert_eq(
    local_file_path("/Users/me/My Project/src"),
    Some("/Users/me/My Project/src"),
  )
  assert_eq(local_file_path("./src/"), Some("./src/"))
  assert_eq(
    local_file_path("pango/aliases.mbt#L5"),
    Some("pango/aliases.mbt#L5"),
  )
  // A bare word stays an ordinary link, and a web destination is never a path.
  assert_eq(local_file_path("src"), None)
  assert_eq(local_file_path("https://example.com/src"), None)
  // The label's own position claim never overrides the destination.
  assert_eq(
    FileReference("pango/aliases.mbt:20").position_path(),
    Some("pango/aliases.mbt"),
  )
}

///|
test "local file URI destinations open decoded filesystem paths" {
  assert_eq(
    local_file_path("file:///Users/me/My%20Project/adw/action_row.mbt#L28"),
    Some("/Users/me/My Project/adw/action_row.mbt#L28"),
  )
  assert_eq(
    local_file_path("file://localhost/Users/me/src/local.mbt#L2"),
    Some("/Users/me/src/local.mbt#L2"),
  )
  // A remote authority or a URI query must not be reinterpreted as a local
  // host path — nor fall through to a browser-navigable anchor.
  assert_eq(local_file_path("file://server/share/remote.mbt#L3"), None)
  assert_eq(
    local_file_path("file:///Users/me/src/query.mbt?download=1#L4"),
    None,
  )
}

///|
fn first_paragraph(block : @cmark.Block) -> @cmark.BlockParagraph? {
  match block {
    Paragraph(node) => Some(node.v)
    Blocks(node) => {
      for child in node.v.iter() {
        if first_paragraph(child) is Some(para) {
          return Some(para)
        }
      }
      None
    }
    _ => None
  }
}

///|
test "plain text flattens inline trees" {
  let doc = @cmark.Doc::from_string("some **bold** and `code`", strict=false)
  guard first_paragraph(doc.block) is Some(para) else {
    fail("expected a paragraph")
  }
  inspect(plain_text(para.inline), content="some bold and code")
}

///|
test "file-path shapes are recognized" {
  // Slash-bearing relative and absolute paths.
  assert_true(is_file_path("frontend/view.mbt"))
  assert_true(is_file_path("/Users/me/Documents/OpenSeek/s1/main.mbt"))
  assert_true(is_file_path("./src/lib.rs"))
  // Bare filenames with a known extension.
  assert_true(is_file_path("README.md"))
  assert_true(is_file_path("moon.pkg"))
  assert_true(is_file_path("config.json"))
  // Position suffixes do not become part of the extension. The raw link is
  // still preserved for the host's exact-file-first existence check.
  assert_true(
    is_file_path(
      "/Users/me/Documents/OpenSeek/desktop/frontend/update.mbt:2738",
    ),
  )
  assert_true(is_file_path("frontend/update.mbt:12345"))
  assert_true(is_file_path("frontend/update.mbt:2738:17"))
  assert_true(is_file_path("frontend/update.mbt#L2738"))
  // Stray surrounding whitespace in a destination is tolerated.
  assert_true(is_file_path(" view.mbt "))
}

///|
test "bare filenames and slash paths alike are clickable" {
  // Exactly the tokens from a real transcript: bare `.mbt` names and
  // slash-bearing paths both qualify; a directory and a bare word do not.
  assert_true(is_file_path("array_nonjs.mbt"))
  assert_true(is_file_path("core/builtin/array_nonjs_test.mbt"))
  assert_true(is_file_path("core/builtin/arraycore_nonjs.mbt"))
  assert_true(is_file_path("array.mbt"))
  assert_true(is_file_path("view.mbt"))
  assert_true(is_file_path("array_test.mbt"))
  assert_false(is_file_path("core"))
  assert_false(is_file_path("core/array/"))
  assert_false(is_file_path("_nonjs"))
}

///|
test "slash paths accept any extension; bare names need a known one" {
  // A `/` makes it a path: any plausible extension lights up, even ones the
  // bare-name allowlist omits.
  assert_true(is_file_path("~/Documents/openseek-deck/dist/openseek.pptx"))
  assert_true(is_file_path("pages/*.page.toml"))
  assert_true(is_file_path("build/out/report.xyz"))
  // A bare name still needs a recognized type.
  assert_true(is_file_path("slides.pptx"))
  assert_true(is_file_path("diagram.png"))
  assert_false(is_file_path("report.xyz"))
  // A trailing slash is a directory.
  assert_false(is_file_path("~/Documents/openseek-deck/"))
}

///|
test "non-paths are left alone" {
  // Identifiers and prose, not files.
  assert_false(is_file_path("OpenFile"))
  assert_false(is_file_path("self.value"))
  assert_false(is_file_path("a.b"))
  assert_false(is_file_path("moon check --target js"))
  assert_false(is_file_path(""))
  // URLs and fragments stay as ordinary links/text.
  assert_false(is_file_path("https://example.com/readme.md"))
  assert_false(is_file_path("mailto:me@example.com"))
  assert_false(is_file_path("#section"))
  // Dotfiles have an empty stem, so they are not treated as an extension.
  assert_false(is_file_path(".gitignore"))
}
