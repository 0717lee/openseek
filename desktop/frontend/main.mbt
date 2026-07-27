///|
#warnings("-alert_unstable")
fn main {
  let app = @rabbita.new(() => {
    let (state, dispatch) = @rabbita.create_state_with_init(
      init=dispatch => (initial_model(), dispatch(Init)),
      update=(dispatch, msg, state) => {
        let (cmd, model) = update(dispatch, msg, state)
        (model, cmd)
      },
    )
    state.view(state => view(dispatch, state))
  })
  app.mount("app")
}
