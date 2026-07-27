///|
/// Rabbita 0.13 compares component state before propagating it. The desktop
/// model still contains mutable collections and JS-backed values, so preserving
/// its existing whole-view refresh requires treating every result as changed.
priv struct AppState(Model)

///|
impl Eq for AppState with fn equal(_, _) {
  false
}

///|
#warnings("-alert_unstable")
fn main {
  let app = @rabbita.new(() => {
    let (state, dispatch) = @rabbita.create_state_with_init(
      init=dispatch => (AppState(initial_model()), dispatch(Init)),
      update=(dispatch, msg, state) => {
        let (cmd, model) = update(dispatch, msg, state.0)
        (AppState(model), cmd)
      },
    )
    state.view(state => view(dispatch, state.0))
  })
  app.mount("app")
}
