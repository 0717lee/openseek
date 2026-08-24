# Desktop design conventions

This document records frontend constraints that should remain true as the
Desktop UI grows. A new feature should follow these constraints instead of
creating a second implementation with similar behavior.

## Select controls

Every user-visible single-choice select menu in the Desktop must use
`openseek_desktop/frontend/select_control`. Call
`@select_control.Control::render` directly, or use a package wrapper that
delegates to that method, such as the composer model and reasoning selectors.

Do not add an `@html.select`, a handwritten `<select>`, or a feature-local
button/listbox implementation. Native selects vary across webviews and cannot
share the Desktop's popup styling and interaction behavior. A second custom
implementation would let keyboard, focus, accessibility, and visual behavior
drift between screens.

If a new select needs behavior or a visual form that `Control` cannot express,
extend `select_control` first. Add the required input or `Presentation` variant,
shared styles, interaction behavior, and tests there, then use it from the
feature. Do not bypass the shared control to meet a local deadline.

### Component and state boundary

`Control` is a shared view component. Its public rendering boundary is:

```moonbit
pub fn Control::render(Self) -> @html.Html
```

It deliberately does not return `@rabbita.Val[@html.Html]`. A Rabbita component
with that return type owns or derives an independently updating subtree. A
select's selected value and open state are application state, so they belong to
the caller's model: either the root model or a containing stateful component.
The caller's `Val` causes its view to run again, and that view renders the
shared `Control` with the new values.

The caller owns:

- the options and stable wire values;
- the selected value, disabled state, and whether this menu is open;
- a stable, unique DOM `id`;
- update messages for toggle, dismiss, and value changes; and
- closing or replacing the open menu during application-level transitions.

`select_control` owns:

- the trigger, popup, groups, option rows, and selected indicator;
- the `listbox`/`option` roles and related ARIA attributes;
- label presentation separately from wire values;
- Arrow, Home, End, Escape, and focus behavior, including dismissal when focus
  leaves the control; and
- the shared `Composer` and `Setting` presentations and their styling.

Document-level click-away handling may dispatch the caller's dismiss message,
but it must not duplicate the control's DOM or keyboard behavior.

### Review requirements

A change that introduces or modifies a select must demonstrate that:

- rendered application markup contains no native `<select>` for that control;
- the feature renders `@select_control.Control` directly or through a documented
  wrapper;
- selection and open-menu transitions are tested in the caller that owns the
  state; and
- shared keyboard, focus, accessibility, or presentation changes are tested in
  `frontend/select_control` rather than copied into feature packages.
