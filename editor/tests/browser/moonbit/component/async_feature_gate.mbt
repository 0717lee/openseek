// Shared deterministic completion gate for the browser scenarios that still
// need to demonstrate a real async renderer. Async feature state machines are
// covered by Viewer whitebox tests; this helper only supplies fixture input.

///|
priv struct AsyncFeatureGate {
  mut resolver : ((String) -> Unit)?
}

///|
fn AsyncFeatureGate::AsyncFeatureGate() -> AsyncFeatureGate {
  { resolver: None, }
}

///|
async fn AsyncFeatureGate::wait(self : AsyncFeatureGate) -> String noraise {
  @js.suspend((resolve : (String) -> Unit, _reject : (Error) -> Unit) => {
    self.resolver = Some(resolve)
  }) catch {
    _ => "empty"
  }
}

///|
fn AsyncFeatureGate::release(self : AsyncFeatureGate, outcome : String) -> Bool {
  match self.resolver {
    Some(resolve) => {
      self.resolver = None
      resolve(outcome)
      true
    }
    None => false
  }
}
