///|
test "esbuild metadata renders relative and CDN distributions" {
  let metafile =
    #|{
    #|  "outputs": {
    #|    "target/web-assets/browser/dist/assets/entry-ABC123.js": {
    #|      "entryPoint": "target/web-assets/browser/input/entry.js",
    #|      "cssBundle": "target/web-assets/browser/dist/assets/entry-DEF456.css"
    #|    },
    #|    "target/web-assets/browser/dist/assets/codicon-FONT1.ttf": {},
    #|    "target/web-assets/browser/dist/assets/entry-DEF456.css": {}
    #|  }
    #|}
    #|
  let metadata = @web_assets.Metadata::parse(
    metafile, "target/web-assets/browser/dist",
  )
  let template = "<title>SeekMoon</title><link href=\"__OPENSEEK_STYLESHEET__\"><script src=\"__OPENSEEK_JAVASCRIPT__\"></script>"
  assert_eq(
    metadata.render_index(template, ""),
    "<title>SeekMoon</title><link href=\"./assets/entry-DEF456.css\"><script src=\"./assets/entry-ABC123.js\"></script>",
  )
  assert_eq(
    metadata.render_index(template, "https://cdn.example.com/openseek/"),
    "<title>SeekMoon</title><link href=\"https://cdn.example.com/openseek/assets/entry-DEF456.css\"><script src=\"https://cdn.example.com/openseek/assets/entry-ABC123.js\"></script>",
  )
  inspect(
    metadata.manifest(),
    content=(
      #|{
      #|  "version": 1,
      #|  "entry": {
      #|    "javascript": "assets/entry-ABC123.js",
      #|    "stylesheet": "assets/entry-DEF456.css"
      #|  },
      #|  "files": [
      #|    "assets/entry-ABC123.js",
      #|    "assets/codicon-FONT1.ttf",
      #|    "assets/entry-DEF456.css"
      #|  ]
      #|}
      #|
    ),
  )
}

///|
test "asset base rejects a non-directory URL" {
  let metafile =
    #|{"outputs":{"target/web-assets/browser/dist/assets/entry.js":{"entryPoint":"target/web-assets/browser/input/entry.js","cssBundle":"target/web-assets/browser/dist/assets/entry.css"},"target/web-assets/browser/dist/assets/entry.css":{}}}
    #|
  let metadata = @web_assets.Metadata::parse(
    metafile, "target/web-assets/browser/dist",
  )
  try
    metadata.render_index(
      "<title>SeekMoon</title>__OPENSEEK_STYLESHEET____OPENSEEK_JAVASCRIPT__", "https://cdn.example.com/openseek",
    )
  catch {
    error => assert_true(error.to_string().contains("ending in '/'"))
  } noraise {
    _ => fail("expected an asset base without a trailing slash to fail")
  }
}
