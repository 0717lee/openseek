///|
async fn main {
  @mermaid_assets.stage("target/vendor-mermaid/cache", "web/dist/mermaid", ".")
  println("Generated pinned Mermaid assets under web/dist/mermaid")
}
