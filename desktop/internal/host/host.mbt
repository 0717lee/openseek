// Transport-agnostic host operations: file browsing, language services,
// skills, self-update, app launching, and connection-owned filesystem/PTY
// state. Typed payloads enter here only after an Endpoint has decoded them.

///|
/// A host-side failure with a user-facing message. Ops raise it; the
/// transport boundary stringifies it into the error the client displays.
pub(all) suberror HostError {
  HostError(String)
} derive(Debug)

///|
impl Show for HostError with fn output(self, logger) {
  match self {
    HostError(message) => logger.write_string(message)
  }
}

///|
/// A request payload that failed to decode — the client sent a shape the
/// method does not accept. Kept apart from `HostError` so transports can
/// report it as a malformed request (JSON-RPC -32602) rather than a failed
/// operation.
pub(all) suberror PayloadError {
  PayloadError(String)
} derive(Debug)

///|
impl Show for PayloadError with fn output(self, logger) {
  match self {
    PayloadError(message) => logger.write_string(message)
  }
}

///|
/// The host ops' process-wide state: the moon-CLI state behind the language
/// services (hover, check diagnostics, symbol search), the engine identity
/// the Moon IDE navigation ops resolve their `moon` from, and the
/// self-update staging state. Filesystem watches are connection-owned below,
/// because two clients may watch different workspaces at the same time.
struct HostState {
  engine : String
  runtime_dir : @pathx.Path?
  moon : MoonCliState
  updates : SelfUpdate
}

///|
/// State owned by one client connection. A desktop page and each remote
/// WebSocket create separate values, so filesystem watches and PTY sessions
/// cannot leak into another client.
struct HostConnection {
  fs_watch : FsWatchActor
  file_search : FileSearchService
  terminal : @terminal.TerminalState
}

///|
pub fn HostConnection::new() -> HostConnection {
  {
    fs_watch: FsWatchActor::new(),
    file_search: FileSearchService::new(),
    terminal: @terminal.new_terminal_state(),
  }
}

///|
/// `engine` is the engine executable (the language services resolve the
/// bundled `moon` next to it); `executable` is the host's own binary, which
/// self-update uses to locate the running .app bundle (absent or non-bundle
/// layouts only lose the in-app install, never the announcement).
pub fn new_host_state(
  engine : String,
  runtime_dir? : @pathx.Path,
  executable? : String,
  app_version? : String = "development",
) -> HostState {
  {
    engine,
    runtime_dir,
    moon: MoonCliState::new(engine, runtime_dir?),
    updates: SelfUpdate::new(runtime_dir, executable, app_version~),
  }
}

///|
/// The background tasks behind the host ops, spawned into the caller's
/// app-lifetime task group: the moon-check diagnostics forwarder and the
/// self-update pump with its startup leftover sweep. These are shared by
/// every connection;
/// connection-owned filesystem watcher tasks start in `HostConnection::run`.
/// Every background task is best-effort: a language-service hiccup degrades
/// that feature, never the connection.
pub fn[G] spawn_host_pumps(
  group : @async.TaskGroup[G],
  state : HostState,
  emit : async (@protocol.Notification) -> Unit,
) -> Unit {
  group.spawn_bg(allow_failure=true, () => {
    state.moon.forward_diagnostics(async fn(push) {
      emit(
        LspDiagnostics({
          root: push.root,
          path: push.path,
          diagnostics: push.diagnostics,
        }),
      )
    })
  })
  group.spawn_bg(allow_failure=true, () => state.updates.run(emit))
}

///|
/// Run the filesystem watcher and PTY pump owned by this connection. Their
/// notifications return only to the same transport instead of entering the
/// process-wide hub.
pub async fn HostConnection::run(
  self : HostConnection,
  emit : async (@protocol.Notification) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    // Closing the request queue is the terminal pump's normal connection-end
    // signal. It must not be tied to the page-reload session sweep below.
    defer self.terminal.shutdown()
    group.spawn_bg(allow_failure=true, () => {
      @terminal.run_terminal_pump(self.terminal, async fn(push) {
        match push {
          Output(id~, sequence~, data~) => {
            let payload : TerminalOutputPayload = {
              id,
              sequence,
              data: @base64.encode(data),
            }
            emit(
              TerminalOutput({
                id: payload.id,
                sequence: payload.sequence,
                data: payload.data,
              }),
            )
          }
          Exited(id~, code~) => {
            let payload : TerminalExitPayload = { id, code }
            emit(TerminalExit({ id: payload.id, code: payload.code }))
          }
        }
      })
    })
    group.spawn_bg(() => self.file_search.run())
    self.fs_watch.run(
      async fn(push) {
        emit(
          FsChanged({
            root: push.root,
            baseline: push.baseline,
            events: push.events.map(event => {
              kind_: event.kind_,
              path: event.path,
              old_path: event.old_path,
            }),
            generation: push.generation,
          }),
        )
      },
      async fn(failure) {
        emit(
          FsWatchFailed({
            root: failure.root,
            message: failure.message,
            generation: failure.generation,
          }),
        )
      },
    )
  })
}

///|
/// A desktop page reload cannot reclaim its old emulator instances. Retire
/// those PTYs before attaching the new page; WebSocket-owned sessions are
/// cancelled automatically with their connection task group.
pub fn HostConnection::close_terminals(self : HostConnection) -> Unit {
  @terminal.close_all_terminals(self.terminal)
}

///|
/// Host-owned endpoints are assembled next to the private operations they
/// invoke. The API package concatenates this catalog with engine/auth
/// endpoints, so these operations do not need one public forwarding method
/// apiece.
pub fn endpoints(
  state : HostState,
  connection : HostConnection,
  on_skills_changed : () -> Unit,
) -> Array[@endpoint.Endpoint] {
  [
    @endpoint.Endpoint::remote(@commands.fs_read_file, async fn(payload) {
      read_file_op(payload) catch {
        error =>
          ReadFileError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_read_file.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_read_directory, async fn(payload) {
      read_directory_op(payload) catch {
        error =>
          ReadDirectoryError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_read_directory.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_search_files, async fn(payload) {
      try {
        let result = search_files_op(connection.file_search, payload)
        SearchResults(
          files=result.files,
          from_cache=result.from_cache,
          limit_hit=result.limit_hit,
          cancelled=result.cancelled,
        )
      } catch {
        error =>
          SearchFilesError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_search_files.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_cancel_search_files, async fn(
      payload,
    ) {
      cancel_search_files_op(connection.file_search, payload) catch {
        error =>
          CancelSearchFilesError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_cancel_search_files.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_clear_file_search_cache, async fn(
      payload,
    ) {
      clear_file_search_cache_op(connection.file_search, payload) catch {
        error =>
          ClearFileSearchCacheError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_clear_file_search_cache.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_stat_files, async fn(payload) {
      stat_files_op(payload) catch {
        error =>
          StatFilesError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_stat_files.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_watch, async fn(payload) {
      try {
        connection.fs_watch.watch(payload)
        FileWatchStarted
      } catch {
        error =>
          FileWatchError(
            @endpoint.Endpoint::record_failure(@commands.fs_watch.name(), error),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_unwatch, async fn(_) {
      try {
        connection.fs_watch.unwatch()
        FileWatchStopped
      } catch {
        error =>
          FileUnwatchError(
            @endpoint.Endpoint::record_failure(
              @commands.fs_unwatch.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.fs_browse, async fn(payload) {
      browse_directory_op(payload)
    }),
    @endpoint.Endpoint::remote(@commands.terminal_open, async fn(payload) {
      terminal_open_op(state, connection.terminal, payload) catch {
        error =>
          TerminalOpenError(
            @endpoint.Endpoint::record_failure(
              @commands.terminal_open.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.terminal_input, async fn(payload) {
      try {
        terminal_input_op(connection.terminal, payload)
        TerminalInputAccepted
      } catch {
        error =>
          TerminalInputError(
            @endpoint.Endpoint::record_failure(
              @commands.terminal_input.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote_sync(@commands.terminal_resize, payload => {
      try {
        terminal_resize_op(connection.terminal, payload)
        TerminalResized
      } catch {
        error =>
          TerminalResizeError(
            @endpoint.Endpoint::record_failure(
              @commands.terminal_resize.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote_sync(@commands.terminal_ack, payload => {
      terminal_ack_op(connection.terminal, payload)
      TerminalOutputAcknowledged
    }),
    @endpoint.Endpoint::remote_sync(@commands.terminal_close, payload => {
      terminal_close_op(connection.terminal, payload)
      TerminalClosed
    }),
    @endpoint.Endpoint::remote(@commands.lsp_open, async fn(payload) {
      try {
        let result = lsp_open_op(state.moon, payload)
        Diagnostics(diagnostics=result.diagnostics)
      } catch {
        error =>
          DiagnosticsError(
            @endpoint.Endpoint::record_failure(@commands.lsp_open.name(), error),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.lsp_hover, async fn(payload) {
      try {
        let result = lsp_hover_op(state.moon, payload)
        Hover(
          value=result.value,
          markdown=result.markdown,
          has_range=result.has_range,
          start_line=result.start_line,
          start_character=result.start_character,
          end_line=result.end_line,
          end_character=result.end_character,
        )
      } catch {
        error =>
          HoverError(
            @endpoint.Endpoint::record_failure(
              @commands.lsp_hover.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.lsp_workspace_symbols, async fn(
      payload,
    ) {
      try {
        let result = workspace_symbols_op(state.moon, payload)
        WorkspaceSymbols(symbols=result.symbols)
      } catch {
        error =>
          WorkspaceSymbolsError(
            @endpoint.Endpoint::record_failure(
              @commands.lsp_workspace_symbols.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.moonide_definition, async fn(payload) {
      try {
        let result = moonide_definition_op(state, payload)
        Locations(locations=result.locations)
      } catch {
        error =>
          NavigationError(
            @endpoint.Endpoint::record_failure(
              @commands.moonide_definition.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.moonide_references, async fn(payload) {
      try {
        let result = moonide_references_op(state, payload)
        Locations(locations=result.locations)
      } catch {
        error =>
          NavigationError(
            @endpoint.Endpoint::record_failure(
              @commands.moonide_references.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.skills_catalog, async fn(_) {
      skills_catalog_op() catch {
        error =>
          SkillsCatalogError(
            @endpoint.Endpoint::record_failure(
              @commands.skills_catalog.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.skills_installed, async fn(_) {
      installed_skills_op() catch {
        error =>
          InstalledSkillsError(
            @endpoint.Endpoint::record_failure(
              @commands.skills_installed.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.skills_install, async fn(payload) {
      install_skill_op(payload, on_skills_changed) catch {
        error =>
          SkillInstallError(
            @endpoint.Endpoint::record_failure(
              @commands.skills_install.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.skills_uninstall, async fn(payload) {
      uninstall_skill_op(payload, on_skills_changed) catch {
        error =>
          SkillUninstallError(
            @endpoint.Endpoint::record_failure(
              @commands.skills_uninstall.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.update_check, async fn(payload) {
      state.updates.check(payload) catch {
        error =>
          Unreachable(
            reason=@endpoint.Endpoint::record_failure(
              @commands.update_check.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote_sync(@commands.update_download, payload => {
      state.updates.start_download(payload) catch {
        error =>
          DownloadError(
            @endpoint.Endpoint::record_failure(
              @commands.update_download.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.update_apply, async fn(_) {
      state.updates.apply() catch {
        error =>
          UpdateApplyError(
            @endpoint.Endpoint::record_failure(
              @commands.update_apply.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.app_list, async fn(_) {
      list_apps_op() catch {
        error =>
          AppListError(
            @endpoint.Endpoint::record_failure(@commands.app_list.name(), error),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.app_launch, async fn(payload) {
      launch_app_op(payload) catch {
        error =>
          AppLaunchError(
            @endpoint.Endpoint::record_failure(
              @commands.app_launch.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.git_branch, async fn(payload) {
      git_branch_op(payload) catch {
        error =>
          GitBranchError(
            @endpoint.Endpoint::record_failure(
              @commands.git_branch.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.git_pull_request, async fn(payload) {
      try {
        let result = git_pull_request_op(payload)
        GitPullRequest(
          pull_request=result.pull_request,
          compare_url=result.compare_url,
          branch=result.branch,
        )
      } catch {
        error =>
          GitPullRequestError(
            @endpoint.Endpoint::record_failure(
              @commands.git_pull_request.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.git_changes, async fn(payload) {
      git_changes_op(payload) catch {
        error =>
          GitChangesError(
            @endpoint.Endpoint::record_failure(
              @commands.git_changes.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.git_original_file, async fn(payload) {
      git_original_file_op(payload) catch {
        error =>
          GitOriginalFileError(
            @endpoint.Endpoint::record_failure(
              @commands.git_original_file.name(),
              error,
            ),
          )
      }
    }),
    @endpoint.Endpoint::remote(@commands.host_open_path, async fn(payload) {
      open_path_op(payload) catch {
        error =>
          OpenPathError(
            @endpoint.Endpoint::record_failure(
              @commands.host_open_path.name(),
              error,
            ),
          )
      }
    }),
  ]
}
