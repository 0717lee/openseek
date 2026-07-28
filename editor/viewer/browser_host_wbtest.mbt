// Algorithm-fidelity browser-idle adapter coverage for pinned VS Code revision
// `b18492a288de038fbc7643aae6de8247029d11bd`,
// `base/common/async.ts:1536-1579`. Tests construct isolated realms so the
// process-global feature selection remains immutable.

///|
fn assert_idle_adapter_path(
  has_request_idle : Bool,
  has_cancel_idle : Bool,
  expects_native : Bool,
) -> Unit raise {
  let target = new_idle_target(has_request_idle, has_cancel_idle)
  let adapter = TokenizationIdleAdapter(target)
  let registration = adapter.schedule(_deadline => ())
  if expects_native {
    assert_eq(idle_target_request_count(target), 1)
    assert_eq(idle_target_timeout_count(target), 0)
  } else {
    assert_eq(idle_target_request_count(target), 0)
    assert_eq(idle_target_timeout_count(target), 1)
    assert_eq(idle_target_timeout_delay(target, 0), 0)
  }
  registration.dispose()
}

///|
test "BIA feature detection uses native idle only when both APIs are functions" {
  assert_idle_adapter_path(false, false, false)
  assert_idle_adapter_path(true, false, false)
  assert_idle_adapter_path(false, true, false)
  assert_idle_adapter_path(true, true, true)
}

///|
test "BIA adapter selects once and the global wrapper is asynchronous cancellable idle" {
  let target = new_idle_target(false, false)
  let adapter = TokenizationIdleAdapter(target)
  idle_target_install_native_api(target)
  let local_registration = adapter.schedule(_deadline => {
    abort("once-selected fallback must be canceled")
  })
  // Adding both native functions after construction cannot change the chosen
  // fallback implementation.
  assert_eq(idle_target_request_count(target), 0)
  assert_eq(idle_target_timeout_count(target), 1)
  local_registration.dispose()
  idle_target_run_timeout(target, 0)

  let global_called = Ref(false)
  let global_handle = schedule_tokenization_idle(_deadline => {
    global_called.val = true
  })
  assert_false(global_called.val)
  global_handle.dispose()
  global_handle.dispose()
}

///|
test "BIA native idle forwards absent and numeric timeout and cancels exact handle once" {
  let target = new_idle_target(true, true)
  let adapter = TokenizationIdleAdapter(target)
  let delivered = Ref(0)
  let remaining = Ref(-1.0)
  let absent = adapter.schedule(deadline => {
    delivered.val += 1
    remaining.val = deadline.time_remaining()
  })
  assert_eq(idle_target_request_count(target), 1)
  assert_false(idle_target_request_had_options(target, 0))
  assert_eq(idle_target_request_handle(target, 0), 41)
  idle_target_run_request(target, 41, false, 7.0)
  assert_eq(delivered.val, 1)
  assert_eq(remaining.val, 7.0)
  absent.dispose()
  absent.dispose()
  assert_eq(idle_target_cancel_count(target), 1)
  assert_eq(idle_target_canceled_handle(target, 0), 41)

  let present = adapter.schedule(_deadline => (), timeout=37.0)
  assert_eq(idle_target_request_count(target), 2)
  assert_true(idle_target_request_had_options(target, 1))
  assert_eq(idle_target_request_timeout(target, 1), 37.0)
  assert_eq(idle_target_request_handle(target, 1), 42)
  present.dispose()
  present.dispose()
  assert_eq(idle_target_cancel_count(target), 2)
  assert_eq(idle_target_canceled_handle(target, 1), 42)
}

///|
test "BIA fallback schedules zero-timeout and exposes a plus-15ms deadline" {
  let target = new_idle_target(false, false)
  idle_target_set_now(target, 100.0)
  let adapter = TokenizationIdleAdapter(target)
  let remaining : Array[Double] = []
  let registration = adapter.schedule(deadline => {
    remaining.push(deadline.time_remaining())
    idle_target_set_now(target, 114.0)
    remaining.push(deadline.time_remaining())
    idle_target_set_now(target, 115.0)
    remaining.push(deadline.time_remaining())
    idle_target_set_now(target, 116.0)
    remaining.push(deadline.time_remaining())
  })
  assert_eq(idle_target_timeout_count(target), 1)
  assert_eq(idle_target_timeout_delay(target, 0), 0)
  assert_true(remaining.is_empty())
  idle_target_run_timeout(target, 0)
  assert_eq(remaining.length(), 4)
  assert_eq(remaining[0], 15.0)
  assert_eq(remaining[1], 1.0)
  assert_eq(remaining[2], 0.0)
  assert_eq(remaining[3], 0.0)
  registration.dispose()
}

///|
test "BIA fallback cancellation is inert idempotent and leaves timeout callback harmless" {
  let target = new_idle_target(false, false)
  let adapter = TokenizationIdleAdapter(target)
  let delivered = Ref(0)
  let registration = adapter.schedule(_deadline => delivered.val += 1)
  assert_eq(idle_target_timeout_count(target), 1)
  registration.dispose()
  registration.dispose()
  // The source does not clear the timer; its callback observes `disposed` and
  // returns before constructing the deadline or invoking the runner.
  assert_eq(idle_target_timeout_count(target), 1)
  idle_target_run_timeout(target, 0)
  assert_eq(delivered.val, 0)
}

///|
extern "js" fn new_idle_target(
  has_request_idle : Bool,
  has_cancel_idle : Bool,
) -> TokenizationIdleTarget =
  #| (hasRequestIdle, hasCancelIdle) => {
  #|   const state = {
  #|     now: 0,
  #|     nextHandle: 41,
  #|     requests: [],
  #|     cancellations: [],
  #|     timeouts: [],
  #|   };
  #|   const target = {
  #|     Date: { now: () => state.now },
  #|     setTimeout: (callback, delay) => {
  #|       state.timeouts.push({ callback, delay });
  #|       return state.timeouts.length;
  #|     },
  #|     __idleState: state,
  #|   };
  #|   const installRequest = () => {
  #|     target.requestIdleCallback = (callback, options) => {
  #|       const handle = state.nextHandle++;
  #|       state.requests.push({ callback, options, handle });
  #|       return handle;
  #|     };
  #|   };
  #|   const installCancel = () => {
  #|     target.cancelIdleCallback = (handle) => {
  #|       state.cancellations.push(handle);
  #|     };
  #|   };
  #|   target.__installNativeApi = () => {
  #|     installRequest();
  #|     installCancel();
  #|   };
  #|   if (hasRequestIdle) installRequest();
  #|   if (hasCancelIdle) installCancel();
  #|   return target;
  #| }

///|
extern "js" fn idle_target_install_native_api(
  target : TokenizationIdleTarget,
) -> Unit = "(target) => target.__installNativeApi()"

///|
extern "js" fn idle_target_set_now(
  target : TokenizationIdleTarget,
  now : Double,
) -> Unit = "(target, now) => { target.__idleState.now = now; }"

///|
extern "js" fn idle_target_request_count(
  target : TokenizationIdleTarget,
) -> Int = "(target) => target.__idleState.requests.length"

///|
extern "js" fn idle_target_request_handle(
  target : TokenizationIdleTarget,
  index : Int,
) -> Int = "(target, index) => target.__idleState.requests[index].handle"

///|
extern "js" fn idle_target_request_had_options(
  target : TokenizationIdleTarget,
  index : Int,
) -> Bool = "(target, index) => target.__idleState.requests[index].options !== undefined"

///|
extern "js" fn idle_target_request_timeout(
  target : TokenizationIdleTarget,
  index : Int,
) -> Double = "(target, index) => target.__idleState.requests[index].options.timeout"

///|
extern "js" fn idle_target_run_request(
  target : TokenizationIdleTarget,
  handle : Int,
  did_timeout : Bool,
  remaining : Double,
) -> Unit =
  #| (target, handle, didTimeout, remaining) => {
  #|   const request = target.__idleState.requests.find(
  #|     (candidate) => candidate.handle === handle,
  #|   );
  #|   if (!request) throw new Error(`missing idle request ${handle}`);
  #|   request.callback({ didTimeout, timeRemaining: () => remaining });
  #| }

///|
extern "js" fn idle_target_cancel_count(target : TokenizationIdleTarget) -> Int = "(target) => target.__idleState.cancellations.length"

///|
extern "js" fn idle_target_canceled_handle(
  target : TokenizationIdleTarget,
  index : Int,
) -> Int = "(target, index) => target.__idleState.cancellations[index]"

///|
extern "js" fn idle_target_timeout_count(
  target : TokenizationIdleTarget,
) -> Int = "(target) => target.__idleState.timeouts.length"

///|
extern "js" fn idle_target_timeout_delay(
  target : TokenizationIdleTarget,
  index : Int,
) -> Int = "(target, index) => target.__idleState.timeouts[index].delay"

///|
extern "js" fn idle_target_run_timeout(
  target : TokenizationIdleTarget,
  index : Int,
) -> Unit = "(target, index) => target.__idleState.timeouts[index].callback()"
