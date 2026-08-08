// The composer's git chip and the popover behind it: ask the host for the
// branch of a conversation's workspace through the `git.branch` method, and
// for that branch's GitHub pull request through `git.pull_request`. Probed
// when a run starts (the workspace is created lazily on the first one), when a
// stored session opens, and when a run finishes (the agent may have created
// the repository, switched branches, or opened a pull request mid-turn). Any
// failure just reads as "nothing to show" — the chip hides.

///|
/// This branch's whole line delta, measured locally: from where it left the
/// remote's default branch all the way to the working tree, untracked files
/// included. `base` names the ref it was measured from, absent when the
/// repository offered none — then the count is uncommitted work alone.
/// `partial` marks a count that stopped short of every untracked file, which
/// the chip says out loud rather than under-reporting quietly.
priv struct DiffStat {
  added : Int
  removed : Int
  files : Int
  base : String?
  partial : Bool
} derive(Eq, Debug)

///|
/// Where a conversation's pull-request lookup stands. `branch` is what the
/// answer describes, so a checkout that moved makes it stale without needing a
/// separate signal. `probing` stays separate from the answer on purpose: a
/// refresh for the same branch leaves the last answer on screen instead of
/// blanking the chip for the second GitHub takes to reply.
priv struct PullRequestProbe {
  branch : String
  probing : Bool
  pull_request : PullRequest?
  compare_url : String?
} derive(Eq, Debug)

///|
/// One pull request as GitHub reports it. `additions`/`deletions` are
/// GitHub's own totals against the pull request's base, which is a different
/// question from the locally measured `DiffStat` — and the reason only one of
/// the two is ever on screen at a time.
priv struct PullRequest {
  number : Int
  title : String
  state : PullRequestState
  draft : Bool
  url : String
  additions : Int
  deletions : Int
  changed_files : Int
  checks : Checks?
} derive(Eq, Debug)

///|
/// A draft is not a fourth state: it is an open pull request that refuses to
/// merge, and the chip says so separately.
priv enum PullRequestState {
  PullRequestOpen
  PullRequestMerged
  PullRequestClosed
} derive(Eq, Debug)

///|
/// The head commit's checks, bucketed into what a chip can show at a glance.
priv struct Checks {
  passed : Int
  failed : Int
  pending : Int
} derive(Eq, Debug)

///|
fn DiffStat::from_reply(reply : @protocol.GitDiffStat) -> DiffStat {
  {
    added: reply.added,
    removed: reply.removed,
    files: reply.files,
    base: reply.base,
    partial: reply.partial,
  }
}

///|
/// Decode one pull request. An unrecognized state is a host speaking a
/// vocabulary this build does not know, which is worth showing nothing for
/// rather than a chip that misreports whether the work has landed.
fn PullRequest::from_reply(reply : @protocol.GitPullRequest) -> PullRequest? {
  let state = match reply.state {
    "open" => PullRequestOpen
    "merged" => PullRequestMerged
    "closed" => PullRequestClosed
    _ => return None
  }
  Some({
    number: reply.number,
    title: reply.title,
    state,
    draft: reply.draft,
    url: reply.url,
    additions: reply.additions,
    deletions: reply.deletions,
    changed_files: reply.changed_files,
    checks: reply.checks.map(checks => {
      passed: checks.passed,
      failed: checks.failed,
      pending: checks.pending,
    }),
  })
}

///|
/// A count of files, spelled for a sentence.
fn file_count(files : Int) -> String {
  if files == 1 {
    "1 file"
  } else {
    "\{files} files"
  }
}

///|
/// The pull request for the branch this conversation has checked out, if the
/// last answer still describes that branch. An answer about a branch the
/// workspace has left is not shown against the branch now checked out, even
/// for the moment before the refresh lands.
fn Conversation::settled_probe(self : Conversation) -> PullRequestProbe? {
  guard self.branch is Some(branch) &&
    self.pull_request is Some(probe) &&
    probe.branch == branch else {
    return None
  }
  Some(probe)
}

///|
/// How the chip is tinted: by CI, which is the part that changes on its own
/// while nobody is looking. A pull request with no checks, and a branch with
/// no pull request, stay neutral.
fn checks_tone(checks : Checks?) -> String {
  guard checks is Some(checks) else { return "none" }
  if checks.failed > 0 {
    "failed"
  } else if checks.pending > 0 {
    "pending"
  } else {
    "passed"
  }
}

///|
/// One line of CI for a tooltip or a popover row.
fn checks_summary(checks : Checks) -> String {
  let parts : Array[String] = []
  if checks.failed > 0 {
    parts.push("\{checks.failed} failed")
  }
  if checks.pending > 0 {
    parts.push("\{checks.pending} running")
  }
  if checks.passed > 0 {
    parts.push("\{checks.passed} passed")
  }
  if parts.is_empty() {
    "no checks"
  } else {
    parts.join(" · ")
  }
}

///|
/// What the chip calls a pull request: its number, plus the one word a state
/// other than plainly open needs. A draft is not a fourth state — it is an
/// open pull request that refuses to merge.
fn pull_request_label(pull_request : PullRequest) -> String {
  let state = match pull_request.state {
    PullRequestOpen => if pull_request.draft { " Draft" } else { "" }
    PullRequestMerged => " Merged"
    PullRequestClosed => " Closed"
  }
  "#\{pull_request.number}\{state}"
}

///|
/// The composer's one git affordance: the branch's pull request when it has
/// one, the branch itself when it does not, tinted by CI — everything else
/// lives in the popover it opens. The composer shares its row with the send
/// button and a resizable side panel, so a fact that is not worth a glance
/// every second belongs behind the click rather than in a fourth chip that
/// pushes the row off its own edge.
fn git_chip(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  conv : Conversation,
) -> @html.Html? {
  guard conv.branch is Some(branch) && !branch.is_empty() else { return None }
  let pull_request = conv.settled_probe().bind(probe => probe.pull_request)
  let (label, tone, summary) = if pull_request is Some(pull_request) {
    let checks = match pull_request.checks {
      Some(checks) => " — CI \{checks_summary(checks)}"
      None => ""
    }
    (
      pull_request_label(pull_request),
      checks_tone(pull_request.checks),
      "\{pull_request.title}\{checks}",
    )
  } else {
    (branch, "none", "On branch \{branch}")
  }
  let open = if model.git_details_open { " open" } else { "" }
  let children : Array[@html.Html] = [
    @html.button(
      class="composer-git-button \{tone}\{open}",
      type_="button",
      title=summary,
      on_click=dispatch(ToggleGitDetails),
      [
        @html.span(class="composer-git-glyph", icon(icon_pull_request)),
        @html.span(class="composer-git-label", label),
      ],
    ),
  ]
  if model.git_details_open {
    // No backdrop element: dismissal rides on `git_dismiss_subscription`,
    // which does not consume the click that closes it.
    children.push(git_details(conv, branch, pull_request))
  }
  Some(@html.div(class="composer-git", children))
}

///|
/// Close the git popover on the next click that is not its own trigger.
///
/// A full-screen backdrop would be the shorter way to write this and the wrong
/// behavior: it swallows that click, so every interaction while the popover
/// happens to be open costs two — one to dismiss, one to act — and a link
/// inside the popover leaves the popover sitting over whatever it just opened.
/// A capture-phase listener closes on the same click that reaches its target.
fn git_dismiss_subscription(emit : @cmd.Emit[Unit]) -> @sub.Sub {
  @sub.custom_sub(
    "composer-git-dismiss",
    Global,
    GitDismissSubscription(emit),
    git_dismiss_sub_loader,
  )
}

///|
priv suberror GitDismissSubscription {
  GitDismissSubscription(@cmd.Emit[Unit])
}

///|
fn git_dismiss_sub_loader(
  payload : Error,
  scheduler : &Scheduler,
) -> @sub.RunningSub? {
  match payload {
    GitDismissSubscription(emit) => {
      let mut emit = emit
      let listener = add_git_dismiss_capture(() => scheduler.add(emit(())))
      Some({
        unload: _ => remove_git_dismiss_capture(listener),
        update_tagger: payload => {
          guard payload is GitDismissSubscription(next) else { return }
          emit = next
        },
      })
    }
    _ => None
  }
}

///|
/// The trigger is excluded because its own handler toggles: closing here first
/// would let that toggle reopen the popover the click was meant to dismiss.
/// Everything else — including the popover's own links — closes it, and the
/// event carries on to whatever was clicked.
extern "js" fn add_git_dismiss_capture(on_dismiss : () -> Unit) -> @js.Value =
  #| (onDismiss) => {
  #|   const listener = (event) => {
  #|     if (event.target?.closest?.(".composer-git-button")) return;
  #|     onDismiss();
  #|   };
  #|   document.addEventListener("click", listener, true);
  #|   return listener;
  #| }

///|
extern "js" fn remove_git_dismiss_capture(listener : @js.Value) -> Unit =
  #| (listener) => document.removeEventListener("click", listener, true)

///|
/// What the chip is a summary of: the branch and where it is measured from,
/// the size of the work on it, and — when there is one — the pull request and
/// its CI, each a link out to GitHub. Rows that link are anchors, so the app's
/// own external-link capture routes them into a dock Browser tab on the
/// desktop and the system browser elsewhere.
fn git_details(
  conv : Conversation,
  branch : String,
  pull_request : PullRequest?,
) -> @html.Html {
  let base = match conv.diffstat {
    Some({ base: Some(base), .. }) => Some("from \{base}")
    _ => None
  }
  let rows : Array[@html.Html] = [
    git_details_row(
      key="Branch",
      value=@html.span(class="composer-git-value", branch),
      note?=base,
    ),
  ]
  if conv.diffstat is Some(stat) {
    let value = if stat.files == 0 {
      @html.span(class="composer-git-clean", "No changes")
    } else {
      @html.span(class="composer-git-diff", [
        @html.span(class="composer-diff-added", "+\{stat.added}"),
        @html.span(class="composer-diff-removed", "−\{stat.removed}"),
      ])
    }
    let counted = if stat.files == 0 {
      None
    } else {
      Some(file_count(stat.files))
    }
    // A count that gave up on the untracked tail says so, rather than passing
    // a floor off as the whole.
    let note = if !stat.partial {
      counted
    } else if counted is Some(counted) {
      Some("\{counted}, untracked tail uncounted")
    } else {
      Some("untracked tail uncounted")
    }
    rows.push(git_details_row(key="Changes", value~, note?))
  }
  if pull_request is Some(pull_request) {
    rows.push(@html.div(class="composer-git-rule", @html.nothing))
    rows.push(
      git_details_link(
        label=pull_request_label(pull_request),
        note=pull_request.title,
        href=pull_request.url,
        tone="none",
      ),
    )
    if pull_request.checks is Some(checks) {
      rows.push(
        git_details_link(
          label="CI",
          note=checks_summary(checks),
          href="\{pull_request.url}/checks",
          tone=checks_tone(Some(checks)),
        ),
      )
    }
  } else if conv.settled_probe() is Some({ compare_url: Some(url), .. }) {
    rows.push(@html.div(class="composer-git-rule", @html.nothing))
    rows.push(
      git_details_link(label="Create pull request", href=url, tone="none"),
    )
  }
  @html.div(class="composer-git-menu", rows)
}

///|
/// One popover row: a key, a value, and secondary text pushed to the right.
fn git_details_row(
  key~ : String,
  value~ : @html.Html,
  note? : String,
) -> @html.Html {
  let children : Array[@html.Html] = [
    @html.span(class="composer-git-key", key),
    value,
  ]
  if note is Some(note) {
    children.push(@html.span(class="composer-git-note", note))
  }
  @html.div(class="composer-git-row", children)
}

///|
/// A popover row that leaves for GitHub.
fn git_details_link(
  label~ : String,
  note? : String,
  href~ : String,
  tone~ : String,
) -> @html.Html {
  let children : Array[@html.Html] = [
    @html.span(class="composer-git-glyph \{tone}", icon(icon_pull_request)),
    @html.span(class="composer-git-value", label),
  ]
  if note is Some(note) {
    children.push(@html.span(class="composer-git-note", note))
  }
  children.push(@html.span(class="composer-git-out", icon(icon_link_external)))
  @html.a(
    class="composer-git-link",
    href~,
    target=Blank,
    rel="noopener noreferrer",
    children,
  )
}

///|
fn fetch_branch(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  cwd : @common.Uri?,
) -> @cmd.Cmd {
  match cwd {
    Some(resource) if !@resource.belongs_to(resource, channel) =>
      return @cmd.none
    _ => ()
  }
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let reply = @interop.bridge_request(channel, @commands.git_branch, {
        session,
        cwd: cwd.map(resource => resource.path),
      }) catch {
        _ => {
          scheduler.add(
            dispatch(BranchLoaded(session~, branch=None, diffstat=None)),
          )
          return
        }
      }
      scheduler.add(
        dispatch(
          BranchLoaded(
            session~,
            branch=reply.branch,
            diffstat=reply.diffstat.map(DiffStat::from_reply),
          ),
        ),
      )
    })
  })
}

///|
test "the chip's tint follows CI, and its label follows the pull request" {
  // Failures outrank running work, which outranks a clean sweep: the chip has
  // one color and it should be the one worth acting on.
  assert_eq(checks_tone(Some({ passed: 4, failed: 2, pending: 1 })), "failed")
  assert_eq(checks_tone(Some({ passed: 4, failed: 0, pending: 1 })), "pending")
  assert_eq(checks_tone(Some({ passed: 4, failed: 0, pending: 0 })), "passed")
  // No checks and no pull request are both "nothing to say", not "passed".
  assert_eq(checks_tone(None), "none")
  assert_eq(
    checks_summary({ passed: 4, failed: 2, pending: 1 }),
    "2 failed · 1 running · 4 passed",
  )
  assert_eq(checks_summary({ passed: 0, failed: 0, pending: 0 }), "no checks")
  let open : PullRequest = {
    number: 697,
    title: "Add a changed-files explorer",
    state: PullRequestOpen,
    draft: false,
    url: "https://github.test/acme/app/pull/697",
    additions: 447,
    deletions: 397,
    changed_files: 18,
    checks: None,
  }
  // A plainly open pull request spends no width on the word; only the states
  // that need one carry it.
  assert_eq(pull_request_label(open), "#697")
  assert_eq(pull_request_label({ ..open, draft: true }), "#697 Draft")
  assert_eq(
    pull_request_label({ ..open, state: PullRequestMerged }),
    "#697 Merged",
  )
  assert_eq(
    pull_request_label({ ..open, state: PullRequestClosed }),
    "#697 Closed",
  )
}

///|
/// Look up `branch`'s pull request. The branch travels with the request so the
/// reply can be matched against the checkout it described: a run that switches
/// branches mid-flight must not have an old answer land on the new branch.
fn fetch_pull_request(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  branch : String,
  cwd : @common.Uri?,
) -> @cmd.Cmd {
  match cwd {
    Some(resource) if !@resource.belongs_to(resource, channel) =>
      return @cmd.none
    _ => ()
  }
  let dispatch = dispatch.map((msg : DeviceMsg) => FromDevice(channel, msg))
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let empty = PullRequestLoaded(
        session~,
        branch~,
        pull_request=None,
        compare_url=None,
      )
      let reply = @interop.bridge_request(channel, @commands.git_pull_request, {
        session,
        cwd: cwd.map(resource => resource.path),
      }) catch {
        _ => {
          scheduler.add(dispatch(empty))
          return
        }
      }
      scheduler.add(
        dispatch(
          PullRequestLoaded(
            session~,
            branch~,
            pull_request=reply.pull_request.bind(PullRequest::from_reply),
            compare_url=reply.compare_url,
          ),
        ),
      )
    })
  })
}
