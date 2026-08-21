#!/usr/bin/env bash

set -euo pipefail

diff_dir="editor/internal/viewer/diff_editor"
code_dir="editor/internal/viewer/code_editor_widget"
facade_dir="editor/viewer"

fail() {
  echo "diff editor architecture check failed: $1" >&2
  exit 1
}

test -f "$diff_dir/moon.pkg" || fail "missing internal diff_editor package"
test -f "$code_dir/moon.pkg" || fail "missing internal code_editor_widget package"

rg -q 'moonbitlang/editor/internal/viewer/code_editor_widget' "$diff_dir/moon.pkg" ||
  fail "diff_editor must depend on code_editor_widget"

if rg -n 'moonbitlang/editor/viewer"|@viewer\.|\bViewer(::|\b)' "$diff_dir" \
  --glob '*.mbt' --glob 'moon.pkg'; then
  fail "diff_editor depends on the public Viewer surface"
fi

if rg -n 'moonbitlang/editor/viewer"|internal/viewer/diff_editor' "$code_dir/moon.pkg"; then
  fail "code_editor_widget has a reverse dependency on public viewer or diff_editor"
fi

if rg -n '\bforce_code_presentation\b|\bBrowserPresentation\b|MarkdownDocumentView' \
  "$code_dir" --glob '*.mbt'; then
  fail "code_editor_widget contains document-presentation policy"
fi

if rg -n '\bCodeEditorRole\b|\bOuterCodeEditorWidget\b|\bPeekPreviewCodeEditorWidget\b|\b(self|viewer)\.role\b' \
  "$code_dir" --glob '*.mbt'; then
  fail "code_editor_widget contains role-based contribution policy"
fi

if rg -n 'pub fn (CodeEditorWidget::(configuration_snapshot|current_code_browser_data|get_view_model)|CodeBrowserData::(view|mouse_handler))' \
  "$code_dir" --glob '*.mbt'; then
  fail "code_editor_widget exports raw configuration, ViewModel, View, or MouseHandler"
fi

if rg -n '@view\.View|MouseHandler|MutationObserver|tail[_-]?balance|viewport_restore_frame|alignment_rebuild_timeout|overview_render_frame' \
  "$diff_dir" --glob '*.mbt'; then
  fail "diff_editor reaches raw editor internals or owns a correction scheduler"
fi

public_widget_fields="$(
  rg -o 'widget[[:space:]]*:[[:space:]]*@code_widget\.CodeEditorWidget' \
    "$facade_dir" --glob '*.mbt' | wc -l | tr -d ' '
)"
test "$public_widget_fields" = "1" ||
  fail "public Viewer must own exactly one CodeEditorWidget field"

public_widget_creates="$(
  rg -o '@code_widget\.CodeEditorWidget::create' \
    "$facade_dir/viewer_facade.mbt" | wc -l | tr -d ' '
)"
test "$public_widget_creates" = "1" ||
  fail "public Viewer must construct exactly one CodeEditorWidget"

public_standalone_descriptors="$(
  rg -o '@code_widget\.CodeEditorContributionDescriptors::standalone' \
    "$facade_dir/viewer_facade.mbt" | wc -l | tr -d ' '
)"
test "$public_standalone_descriptors" = "1" ||
  fail "public Viewer must explicitly select standalone contributions"

diff_widget_creates="$(
  rg -o '@code_widget\.CodeEditorWidget::create' "$diff_dir" \
    --glob '*.mbt' --glob '!**/*_test.mbt' --glob '!**/*_wbtest.mbt' |
    wc -l | tr -d ' '
)"
test "$diff_widget_creates" = "2" ||
  fail "DiffEditorEditors must construct exactly two CodeEditorWidgets"

diff_pane_descriptors="$(
  rg -o '@code_widget\.CodeEditorContributionDescriptors::diff_pane' \
    "$diff_dir/editors.mbt" | wc -l | tr -d ' '
)"
test "$diff_pane_descriptors" = "2" ||
  fail "DiffEditorEditors must explicitly select diff-pane contributions twice"

peek_preview_descriptors="$(
  rg -o 'CodeEditorContributionDescriptors::peek_preview' \
    "$code_dir/definition_peek_host.mbt" | wc -l | tr -d ' '
)"
test "$peek_preview_descriptors" = "1" ||
  fail "References Peek must explicitly select one preview contribution set"

diff_view_model_creates="$(
  rg -o 'let view_model[[:space:]]*=[[:space:]]*DiffEditorViewModel\(' \
    "$diff_dir" --glob '*.mbt' --glob '!**/*_test.mbt' \
    --glob '!**/*_wbtest.mbt' | wc -l | tr -d ' '
)"
test "$diff_view_model_creates" = "1" ||
  fail "DiffEditorWidget must construct exactly one DiffEditorViewModel"
