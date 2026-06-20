///|
fn strip(markdown : String) -> String {
  @markdown_comments.without_comments(markdown)
}

///|
fn visible_cr(markdown : String) -> String {
  markdown.split("\r").collect().join("|")
}

///|
test "without comments keeps ordinary markdown unchanged" {
  inspect(
    strip("# Title\n\nBody with <span>html</span>.\n"),
    content="# Title\n\nBody with <span>html</span>.\n",
  )
}

///|
test "top-level block comments are removed" {
  inspect(
    strip(
      (
        #|# Title
        #|
        #|<!-- hidden block
        #|still hidden -->
        #|
        #|Visible.
        #|
      ),
    ),
    content=(
      #|# Title
      #|
      #|
      #|
      #|Visible.
      #|
    ),
  )
}

///|
test "single-line block comments can share a line with visible text" {
  inspect(
    strip("<!-- hidden --> Visible after block comment.\n"),
    content=" Visible after block comment.\n",
  )
}

///|
test "adjacent comment ranges are all removed" {
  inspect(
    strip("<!-- first --> Visible <!-- second --> after.\n"),
    content=" Visible  after.\n",
  )
}

///|
test "inline comments are removed from paragraphs" {
  inspect(
    strip("Visible <!-- hidden inline --> text.\n"),
    content="Visible  text.\n",
  )
}

///|
test "multiline inline comments are removed from paragraphs" {
  inspect(strip("foo <!-- hidden\ncomment --> bar\n"), content="foo  bar\n")
}

///|
test "comments in headings and emphasis are removed" {
  inspect(
    strip("# Title <!-- hidden --> now\n\nA **bold <!-- hidden --> word**.\n"),
    content="# Title  now\n\nA **bold  word**.\n",
  )
}

///|
test "comments in blockquotes and lists are removed" {
  inspect(
    strip(
      (
        #|> Quoted <!-- hidden --> text.
        #|
        #|- First <!-- hidden --> item
        #|- <!-- hidden --> second
        #|
      ),
    ),
    content=(
      #|> Quoted  text.
      #|
      #|- First  item
      #|-  second
      #|
    ),
  )
}

///|
test "comments in table cells are removed" {
  inspect(
    strip(
      (
        #|| Left | Right |
        #|| --- | --- |
        #|| a <!-- hidden --> cell | <!-- hidden --> b |
        #|
      ),
    ),
    content=(
      #|| Left | Right |
      #|| --- | --- |
      #|| a  cell |  b |
      #|
    ),
  )
}

///|
test "fenced and indented code keep comment text" {
  inspect(
    strip(
      (
        #|```markdown
        #|<!-- kept in fenced code -->
        #|```
        #|
        #|    <!-- kept in indented code -->
        #|
      ),
    ),
    content=(
      #|```markdown
      #|<!-- kept in fenced code -->
      #|```
      #|
      #|    <!-- kept in indented code -->
      #|
    ),
  )
}

///|
test "plain html blocks are preserved" {
  inspect(strip("<div>kept html</div>\n"), content="<div>kept html</div>\n")
}

///|
test "comments inside multiline html blocks are removed" {
  inspect(
    strip(
      (
        #|<div>
        #|<!-- hidden inside html block -->
        #|kept html block
        #|</div>
        #|
      ),
    ),
    content=(
      #|<div>
      #|
      #|kept html block
      #|</div>
      #|
    ),
  )
}

///|
test "comment-looking html attributes are preserved" {
  inspect(
    strip(
      (
        #|<div data-x="<!-- not a markdown comment -->">
        #|kept
        #|</div>
        #|
      ),
    ),
    content=(
      #|<div data-x="<!-- not a markdown comment -->">
      #|kept
      #|</div>
      #|
    ),
  )
}

///|
test "raw text html blocks preserve comment-looking content" {
  inspect(
    strip(
      (
        #|<script type="text/javascript">
        #|const marker = "<!-- not a markdown comment -->";
        #|</script>
        #|
        #|<style>
        #|/* <!-- not a markdown comment --> */
        #|</style>
        #|
        #|<pre><!-- kept in preformatted content --></pre>
        #|
        #|<textarea><!-- kept in textarea content --></textarea>
        #|
      ),
    ),
    content=(
      #|<script type="text/javascript">
      #|const marker = "<!-- not a markdown comment -->";
      #|</script>
      #|
      #|<style>
      #|/* <!-- not a markdown comment --> */
      #|</style>
      #|
      #|<pre><!-- kept in preformatted content --></pre>
      #|
      #|<textarea><!-- kept in textarea content --></textarea>
      #|
    ),
  )
}

///|
test "comments after raw text html blocks are removed" {
  inspect(
    strip(
      (
        #|<pre>code</pre><!-- hidden -->
        #|<script></script><!-- hidden -->
        #|<textarea>x</textarea><!-- hidden -->
        #|
      ),
    ),
    content=(
      #|<pre>code</pre>
      #|<script></script>
      #|<textarea>x</textarea>
      #|
    ),
  )
}

///|
test "inline raw text html preserves comment-looking content" {
  inspect(
    strip(
      (
        #|Text <script>const marker = "<!-- not a markdown comment -->";</script> more
        #|Text <style>/* <!-- not a markdown comment --> */</style> more
        #|Text <pre><!-- kept in preformatted content --></pre> more
        #|Text <textarea><!-- kept in textarea content --></textarea> more
        #|Text <title><!-- kept in title content --></title> more
        #|
      ),
    ),
    content=(
      #|Text <script>const marker = "<!-- not a markdown comment -->";</script> more
      #|Text <style>/* <!-- not a markdown comment --> */</style> more
      #|Text <pre><!-- kept in preformatted content --></pre> more
      #|Text <textarea><!-- kept in textarea content --></textarea> more
      #|Text <title><!-- kept in title content --></title> more
      #|
    ),
  )
}

///|
test "comments after inline raw text html are removed" {
  inspect(
    strip(
      (
        #|Text <script></script><!-- hidden --> more
        #|Text <pre>code</pre><!-- hidden --> more
        #|Text <title>title</title><!-- hidden --> more
        #|
      ),
    ),
    content=(
      #|Text <script></script> more
      #|Text <pre>code</pre> more
      #|Text <title>title</title> more
      #|
    ),
  )
}

///|
test "inline raw text state spans markdown blocks" {
  inspect(
    strip(
      (
        #|Text <script>
        #|const marker = "<!-- not a markdown comment -->";
        #|</script><!-- hidden --> more
        #|
      ),
    ),
    content=(
      #|Text <script>
      #|const marker = "<!-- not a markdown comment -->";
      #|</script> more
      #|
    ),
  )
}

///|
test "self-closing raw text tags do not protect following comments" {
  inspect(
    strip(
      (
        #|<pre/> <!-- hidden --> after
        #|<script src="x"/> <!-- hidden --> after
        #|<style/> <!-- hidden --> after
        #|<textarea/> <!-- hidden --> after
        #|<title/> <!-- hidden --> after
        #|
      ),
    ),
    content=(
      #|<pre/>  after
      #|<script src="x"/>  after
      #|<style/>  after
      #|<textarea/>  after
      #|<title/>  after
      #|
    ),
  )
}

///|
test "same-line html block comments are removed" {
  inspect(
    strip("<div><!-- hidden same-line html block -->kept html inline</div>\n"),
    content="<div>kept html inline</div>\n",
  )
}

///|
test "multiple html block comments are removed independently" {
  inspect(
    strip("<section><!-- one -->kept<!-- two --></section>\n"),
    content="<section>kept</section>\n",
  )
}

///|
test "unicode before comments keeps byte ranges aligned" {
  inspect(
    strip("Hello 月 <!-- hidden --> world\n"),
    content="Hello 月  world\n",
  )
}

///|
test "cr-only line endings preserve preceding text" {
  inspect(
    visible_cr(
      strip("Before\r<!-- hidden --> Visible <!-- second --> after\rAfter\r"),
    ),
    content="Before| Visible  after|After|",
  )
}

///|
test "crlf line endings preserve visible text" {
  inspect(
    visible_cr(strip("Before\r\n<!-- hidden --> Visible\r\nAfter\r\n")),
    content="Before|\n Visible|\nAfter|\n",
  )
}

///|
test "incomplete comments are preserved" {
  inspect(
    strip("Before <!-- hidden\nAfter\n"),
    content="Before <!-- hidden\nAfter\n",
  )
}

///|
test "degenerate html comments are removed" {
  inspect(
    strip(
      (
        #|<!-->
        #|<!--->
        #|foo <!--> bar
        #|foo <!---> bar
        #|Visible.
        #|
      ),
    ),
    content=(
      #|
      #|
      #|foo <!--> bar
      #|foo <!---> bar
      #|Visible.
      #|
    ),
  )
}
