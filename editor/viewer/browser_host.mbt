///|
#external
priv type TokenizationIdleTarget

///|
#external
priv type NativeIdleDeadline

///|
priv enum TokenizationIdleImplementation {
  NativeIdleCallbacks
  TimeoutFallback
}

///|
/// MoonBit owns the once-selected scheduling branch and every cancellation /
/// fallback-deadline lifetime. The target stays opaque because it is either
/// the browser realm or the isolated realm-shaped white-box seam.
priv struct TokenizationIdleAdapter {
  target : TokenizationIdleTarget
  implementation : TokenizationIdleImplementation
}

///|
extern "js" fn global_tokenization_idle_target_js() -> TokenizationIdleTarget = "() => globalThis"

///|
extern "js" fn idle_target_has_request_idle(
  target : TokenizationIdleTarget,
) -> Bool = "(target) => typeof target.requestIdleCallback === 'function'"

///|
extern "js" fn idle_target_has_cancel_idle(
  target : TokenizationIdleTarget,
) -> Bool = "(target) => typeof target.cancelIdleCallback === 'function'"

///|
extern "js" fn idle_target_request(
  target : TokenizationIdleTarget,
  callback : (NativeIdleDeadline) -> Unit,
) -> Int = "(target, callback) => target.requestIdleCallback(callback)"

///|
extern "js" fn idle_target_request_with_timeout(
  target : TokenizationIdleTarget,
  callback : (NativeIdleDeadline) -> Unit,
  timeout : Double,
) -> Int = "(target, callback, timeout) => target.requestIdleCallback(callback, { timeout })"

///|
extern "js" fn idle_target_cancel(
  target : TokenizationIdleTarget,
  handle : Int,
) -> Unit = "(target, handle) => target.cancelIdleCallback(handle)"

///|
extern "js" fn idle_target_set_timeout_zero(
  target : TokenizationIdleTarget,
  callback : () -> Unit,
) -> Unit = "(target, callback) => { target.setTimeout(callback, 0); }"

///|
extern "js" fn idle_target_wall_clock_now(
  target : TokenizationIdleTarget,
) -> Double = "(target) => target.Date.now()"

///|
extern "js" fn native_idle_deadline_time_remaining(
  deadline : NativeIdleDeadline,
) -> Double = "(deadline) => deadline.timeRemaining()"

///|
/// The common tokenization contract intentionally exposes only the
/// immediately-read remaining budget. Upstream `didTimeout` is N-A because no
/// local tokenizer branch consumes it.
priv struct BrowserIdleDeadline {
  read_time_remaining : () -> Double
}

///|
fn BrowserIdleDeadline::time_remaining(self : BrowserIdleDeadline) -> Double {
  (self.read_time_remaining)()
}

///|
/// Selects Monaco's browser-idle implementation once for one realm. This is an
/// algorithm-fidelity port of `base/common/async.ts:1536-1579`: both native
/// functions are required, the choice is immutable, and the fallback publishes
/// a 15ms wall-clock budget from its eventual zero-timeout callback.
fn TokenizationIdleAdapter::TokenizationIdleAdapter(
  target : TokenizationIdleTarget,
) -> TokenizationIdleAdapter {
  let implementation = if idle_target_has_request_idle(target) &&
    idle_target_has_cancel_idle(target) {
    NativeIdleCallbacks
  } else {
    TimeoutFallback
  }
  { target, implementation }
}

///|
fn TokenizationIdleAdapter::schedule(
  self : TokenizationIdleAdapter,
  callback : (BrowserIdleDeadline) -> Unit,
  timeout? : Double,
) -> @base_common.Disposable {
  match self.implementation {
    NativeIdleCallbacks => {
      let deliver = (deadline : NativeIdleDeadline) => {
        callback({
          read_time_remaining: () => {
            native_idle_deadline_time_remaining(deadline)
          },
        })
      }
      let handle = match timeout {
        Some(timeout) =>
          idle_target_request_with_timeout(self.target, deliver, timeout)
        None => idle_target_request(self.target, deliver)
      }
      @base_common.Disposable::from(() => {
        idle_target_cancel(self.target, handle)
      })
    }
    TimeoutFallback => {
      let active = Ref(true)
      idle_target_set_timeout_zero(self.target, () => {
        if !active.val {
          return
        }
        let end = idle_target_wall_clock_now(self.target) + 15.0
        callback({
          read_time_remaining: () => {
            (end - idle_target_wall_clock_now(self.target)).max(0.0)
          },
        })
      })
      @base_common.Disposable::from(() => active.val = false)
    }
  }
}

///|
/// Monaco's `runWhenGlobalIdle`: bind the once-selected adapter to the same
/// `globalThis` realm used for feature detection (`async.ts:1536-1579`).
let browser_tokenization_idle_adapter : TokenizationIdleAdapter = TokenizationIdleAdapter(
  global_tokenization_idle_target_js(),
)

///|
fn schedule_tokenization_idle(
  callback : (@model.TokenizationIdleDeadline) -> Unit,
) -> @base_common.Disposable {
  browser_tokenization_idle_adapter.schedule(deadline => {
    callback(TokenizationIdleDeadline(() => deadline.time_remaining()))
  })
}

///|
let browser_tokenization_scheduler : @model.TokenizationScheduler = TokenizationScheduler(
  idle=schedule_tokenization_idle,
  zero_timeout=callback => @base_browser.schedule_timeout(callback, 0),
  delay=(milliseconds, callback) => {
    @base_browser.schedule_timeout(callback, milliseconds)
  },
  now=@base_browser.monotonic_now_ms,
)

///|
/// Starts every task in its own JavaScript async continuation and resumes when
/// the last continuation finishes. Completion callbacks therefore observe real
/// completion order while shared packages remain independent of the browser's
/// async runtime.
async fn run_async_tasks_concurrently(tasks : Array[async () -> Unit]) -> Unit {
  if tasks.is_empty() {
    return
  }
  @js.suspend((resolve : (Unit) -> Unit, _reject : (Error) -> Unit) => {
    let remaining = Ref(tasks.length())
    for task in tasks {
      @js.async_run(() => {
        task() catch {
          _ => ()
        }
        remaining.val -= 1
        if remaining.val == 0 {
          resolve(())
        }
      })
    }
  }) catch {
    _ => ()
  }
}

///|
/// Starts one detached JS async continuation. Freshness/cancellation ownership
/// remains with the request stamp captured by the continuation.
fn launch_async_task(task : async () -> Unit noraise) -> Unit {
  @js.async_run(task)
}
