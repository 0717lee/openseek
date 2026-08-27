# Desktop UX guidelines

This document defines interaction principles that should remain true as the
Desktop product grows. It complements [`DESIGN.md`](DESIGN.md): that document
defines the visual language, while this one defines how the interface behaves,
communicates, and protects the user's attention. CSS implementation rules remain
in [`styles/README.md`](styles/README.md).

> **Calm by default. Explicit when consequences matter. Recoverable when
> things go wrong.**

These guidelines deliberately avoid application-specific state machines and
component APIs. A feature specification may add more detail, but should not
weaken these principles. In this document, **must** is a product requirement;
**must not**, **never**, and **do not** are product prohibitions; **should** and
**prefer** are defaults that need a clear reason to override; and **avoid** means
**should not**.

## Design for sustained work

Desktop is a high-density work environment. Its default state should be calm,
stable, and readable for long sessions.

- Preserve the user's focus, selection, scroll position, open context, and
  unfinished input across background updates whenever possible.
- Do not steal focus to report progress, completion, or a non-blocking error.
- Do not move controls merely because nearby content changed. Reserve space or
  update in place when a predictable boundary can prevent layout shift.
- If live content is following the latest output, stop auto-following as soon
  as the user scrolls away. Never pull them back without an explicit action.
- Direct manipulation must track the pointer or keyboard immediately. Do not
  add a trailing transition to dragging, resizing, typing, selection, or focus.
- Lead with one visual focal point. Multiple animations or alerts competing in
  different regions make the interface feel less trustworthy, not more active.

This applies Atlassian's guidance to keep high-frequency interactions subtle
and to use one clear focal point, and Fluent's guidance to constrain motion to
the element in focus ([Atlassian Motion], [Fluent Motion]).

## Put feedback near its cause

Every intentional user action must receive prompt acknowledgment. The feedback
should appear at the narrowest surface that fully explains the effect.

Use this escalation order:

1. Update the control or content that owns the action.
2. Show persistent status in the affected view or workspace.
3. Use a notification when relevant work finishes elsewhere or needs attention
   outside its original context.
4. Use a modal only when work cannot safely continue without an immediate
   decision.

Do not use a disappearing notification as the only record of an actionable
error, an unfinished operation, or a condition that continues to affect the
work. A brief notice may be enough for a fully recovered failure with no
remaining consequence. Avoid repeated notifications, and do not interrupt the
user merely to announce routine success. VS Code likewise recommends keeping
progress inside its relevant view, reserving global progress notifications for
escalation, and using modals only for immediate input ([VS Code Notifications],
[VS Code Status Bar]). Apple recommends matching the interruption level to the
importance of the feedback ([Apple Feedback]).

## Communicate activity honestly

Feedback should answer the useful questions: what is happening, what it affects,
whether the user can continue, and what they can do next.

Expose a status only when it changes the user's understanding, next useful
action, confidence in what is shown, or recovery options. Internal stages that
change none of these should remain internal.

- Prefer a short, specific verb and object over a generic label such as
  “Working”.
- Acknowledge that an action was accepted without implying that it completed.
- Use determinate progress whenever progress can be measured. Never invent a
  percentage or time estimate, and never let a multi-stage indicator appear to
  rewind.
- Use an indeterminate indicator only while useful progress cannot be measured.
  For a long operation, add meaningful phase text, details or logs, timeout
  behavior, and cancellation when cancellation is safe.
- If an operation stalls or fails, replace passive activity feedback with an
  explanation and a recovery action. Do not leave an indicator running after
  the operation has ended.

Use these elapsed-wait thresholds as shared defaults. Start at the appropriate
level when a long wait is known in advance; otherwise escalate feedback when an
operation crosses a boundary:

| Elapsed wait | Default feedback |
| --- | --- |
| Under `1s` | No loading animation; acknowledge input in the initiating control |
| `1–3s` | A small, local, labeled activity indicator |
| Over `3s` | Descriptive status and measurable progress when available |

An AI conversation may need immediate acknowledgment even when the expected
wait is short, because silence breaks the conversational turn. These thresholds
come from [Fluent Wait UX]. Its progress guidance also favors determinate
progress, continuous progress across related phases, and specific status text
([Fluent Progress]). VS Code recommends details, cancellation, and timeout
behavior for long-running progress ([VS Code Notifications]).

## Keep readable content stationary

Readable content must remain readable while the system is active.

- Never pulse, blink, shimmer, jitter, or repeatedly fade the opacity of a
  sentence, message, label, command, diagnostic, log line, or other readable
  content.
- Put activity motion in a small adjacent indicator. Static text, an icon, a
  shape, or a value must still communicate the state when motion is removed.
- Do not replay entrance animations when restoring history or loading a saved
  view. Do not apply per-item entrance motion to a large batch. Animate a small
  amount of genuinely new content only when motion helps explain where it came
  from.
- Do not continuously animate several indicators for the same operation. Use
  one primary signal and let secondary surfaces remain static.
- Stop an activity animation as soon as the activity ends.

This is intentionally stricter than WCAG's minimum. WCAG requires a way to
pause, stop, or hide nonessential auto-started motion or blinking that lasts
more than five seconds beside other content, and notes that blinking can make
the rest of the interface difficult to use ([WCAG Pause, Stop, Hide]). A calm
work surface should avoid creating that distraction in the first place.

## Use motion as information

Motion may explain a change, preserve spatial continuity, acknowledge an
interaction, or direct attention. If removing an animation loses no useful
information or context, remove it.

Choose motion by semantic purpose rather than inventing durations for individual
components. The following values are Desktop defaults at the fast end of the
ranges recommended for frequently used productivity interfaces:

| Motion role | Duration | Typical purpose |
| --- | ---: | --- |
| Instant | `0ms` | Focus, selection, direct manipulation, critical feedback |
| Micro | `50ms` or `100ms` | Hover, press, color, or compact disclosure feedback |
| Small enter | `150ms` | Popup, tooltip, or inline content entering |
| Small exit | `100ms` | Dismissal that should clear the way quickly |
| Context transition | `200ms` or `250ms` | Panel or modal transition that establishes location |
| Rare large spatial transition | `400ms` maximum | Movement whose spatial relationship aids orientation |

Implementations should choose the nearest shared duration from `0ms`, `50ms`,
`100ms`, `150ms`, `200ms`, `250ms`, and `400ms`. Do not introduce a
component-specific duration when a shared value expresses the same purpose.

The duration includes the whole transition; it must not delay input, focus,
error presentation, or assistive-technology feedback. Frequent interactions
should stay at or below `150ms`. Exits should usually be faster and less
prominent than entrances.

- Use `ease-out` for entrances, `ease-in` for exits, and `ease-in-out` for an
  element that repositions or transforms in place.
- Use linear easing only for motion that represents a real constant rate, such
  as rotation.
- Prefer a quick fade for large context changes unless spatial movement teaches
  where content came from or where it went.
- Animate at most one or two visual properties. Avoid combining translation,
  scale, blur, and opacity into ornamental choreography.
- Never require a user to wait for an animation before acting.

Fluent defines functional motion as a way to identify the next step and explain
UI change. Atlassian describes motion as duration, easing, and property;
recommends semantic tokens; and gives `50–150ms` for interaction feedback and
`150–400ms` for transitions ([Fluent Motion], [Atlassian Motion],
[Atlassian Applying Motion]). Apple similarly recommends brief, precise,
optional motion and avoiding extra motion in frequent interactions
([Apple Motion]).

## Limit continuous motion

Continuous motion is a scarce attention signal. Use it only when an operation
is currently active and a static state would leave meaningful uncertainty.

- Keep a loop small and visually quiet. It must not change the geometry or
  legibility of nearby content.
- Use at most one primary continuous signal for an operation. Surfaces that
  mirror the same activity should use static status.
- Do not use a loop to advertise importance, unread content, success, or a state
  that is waiting for the user. Static text, badges, or icons are clearer.
- Prefer determinate progress over a loop whenever honest measurement exists.
- If nonessential motion would continue for more than five seconds alongside
  usable content, remove it or provide a way to pause, stop, or hide it.

See [WCAG Pause, Stop, Hide], [Fluent Progress], and [Atlassian Motion].

## Support reduced motion completely

Reduced motion is a supported product mode, not an optional polish pass.

- Start from a usable static presentation and add nonessential motion only
  under `prefers-reduced-motion: no-preference` where practical.
- Under reduced motion, remove spatial transitions, scale, bounce, parallax,
  blinking, pulsing, shimmer, and decorative rotation. Make the corresponding
  state change immediate.
- Replace an essential animated activity cue with stable text and an icon or
  progress value. Motion must never be the only carrier of information.
- Test complete workflows with all animation disabled. Focus order, status,
  progress, errors, and control availability must remain understandable.

W3C documents the static-first media-query pattern in Technique C39. Atlassian
requires the interface to remain usable with motion off, while Apple recommends
reducing repetitive and spatial motion in response to the platform preference
([W3C Technique C39], [Atlassian Motion], [Apple Accessibility]).

## Keep users in control

The interface should make exploration safe and recovery inexpensive.

- Prefer reversible actions. Preserve drafts, selections, and completed work
  when cancellation, navigation, or an error does not require discarding them.
- Offer Cancel, Undo, Retry, or an equivalent recovery path when it is safe and
  meaningful. Explain irreversible consequences before commitment.
- An error should state what happened, what was affected, what remains safe
  when relevant, and the next useful action. Keep exact diagnostics available
  without forcing everyone to read them first.
- Do not add confirmation to routine, expected, reversible actions. Interrupt
  for unexpected and difficult-to-recover consequences instead.

For automated or AI-driven actions, also make the scope and likely consequence
clear, ask for clarification when uncertainty makes acting risky, and make it
easy to stop, dismiss, or correct the system. Claims of completion should be
supported by inspectable results rather than confidence-signaling animation or
language. These rules follow [Apple Design Principles] and Microsoft's
[Human-AI Interaction Guidelines].

## Make state changes perceivable

Do not rely on color, animation, sound, or position alone to communicate state.
Use concise text and a recognizable icon or shape where appropriate.

Meaningful status changes must be available to assistive technology without
moving keyboard focus. Announce changes that affect the user's next action,
the interface's availability, or a final result, and coalesce frequent updates.
Do not announce every internal phase, streamed fragment, progress tick, or
decorative update. Critical feedback and focus indicators must appear
immediately rather than waiting for an entrance animation to finish.

This follows WCAG's requirement that status messages be programmatically
determinable without receiving focus and its intent to avoid unnecessary
interruption ([WCAG Status Messages]).

## Review questions

Before accepting a new interaction, verify:

- Does every user action receive prompt, local acknowledgment?
- Can background updates occur without losing focus, selection, scroll position,
  or unfinished input?
- Is interruption proportional to the consequence and need for action?
- Does each animation explain a change or relationship? If removed, is anything
  actually lost?
- Does any readable content move, pulse, blink, or fade while it must be read?
- Are concurrent and continuous animations reduced to one clear focal signal?
- Is progress honest, contextual, cancellable when safe, and explicit when it
  stalls or fails?
- Can the user recover without losing unrelated work?
- Is the workflow complete and understandable with motion disabled?
- Are important changes conveyed without relying on color, animation, or focus
  movement alone?

## References and influences

These are primary sources used to derive the guidelines above. They are
references for principles, not framework or component dependencies.

- [Fluent Motion], [Fluent Wait UX], and [Fluent Progress]: functional motion,
  easing, wait thresholds, contextual feedback, and honest progress.
- [Atlassian Motion] and [Atlassian Applying Motion]: semantic motion roles,
  duration ranges, attention management, entrance and exit behavior, and
  reduced motion.
- [VS Code Notifications] and [VS Code Status Bar]: contextual progress,
  notification restraint, background status, cancellation, and modal use in a
  high-density developer tool.
- [WCAG Pause, Stop, Hide], [W3C Technique C39], and [WCAG Status Messages]:
  accessibility requirements and techniques for persistent motion, platform
  motion preferences, and non-interrupting status announcements.
- [Apple Motion], [Apple Feedback], [Apple Accessibility], and
  [Apple Design Principles]: purposeful motion, proportional interruption,
  recovery, and multimodal feedback.
- [Human-AI Interaction Guidelines]: expectation setting, uncertainty,
  dismissal, correction, explanation, and user control for AI-driven behavior.

[Apple Accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[Apple Design Principles]: https://developer.apple.com/design/human-interface-guidelines/design-principles
[Apple Feedback]: https://developer.apple.com/design/human-interface-guidelines/feedback
[Apple Motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[Atlassian Applying Motion]: https://atlassian.design/foundations/motion/applying-motion
[Atlassian Motion]: https://atlassian.design/foundations/motion
[Fluent Motion]: https://fluent2.microsoft.design/motion
[Fluent Progress]: https://fluent2.microsoft.design/components/web/react/core/progressbar/usage
[Fluent Wait UX]: https://fluent2.microsoft.design/wait-ux
[Human-AI Interaction Guidelines]: https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/
[VS Code Notifications]: https://code.visualstudio.com/api/ux-guidelines/notifications
[VS Code Status Bar]: https://code.visualstudio.com/api/ux-guidelines/status-bar
[WCAG Pause, Stop, Hide]: https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html
[W3C Technique C39]: https://www.w3.org/WAI/WCAG22/Techniques/css/C39
[WCAG Status Messages]: https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html
