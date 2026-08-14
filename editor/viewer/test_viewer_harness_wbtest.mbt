// Headless behavior-test harness — the MoonBit analog of vscode's
// editor/test/browser/testCodeEditor.ts. Drives a real Viewer + ViewModel +
// CursorsController over an in-memory model WITHOUT attaching a DOM view
// (mirrors TestCodeEditor._createView returning null), so tests assert on
// semantic state — positions, ranges, projected view lines, frames — instead
// of rendered pixels.
//
// The seam is `Viewer::attach_model` (attach_model.mbt): it builds the
// tokenized document, view model, and cursor context and stores
// them synchronously before `schedule_render`. Only the DOM flush is deferred,
// and `schedule_render`/`flush_render` already no-op while the model has no
// browser bundle. So an unattached viewer has fully-populated semantic state
// after `set_model` — no DOM, no requestAnimationFrame, no measurement needed.

///|
/// Builds a TextModel from raw text. The analog of `instantiateTextModel`.
fn test_model(
  text : String,
  language_id? : String = "plaintext",
) -> @model.TextModel {
  TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="model",
      path="/test-model",
    ),
    "test-model",
    language_id,
    1,
    "",
    text,
  )
}

///|
/// `withTestCodeEditor`: spin up a headless viewer over `text`, run `body`,
/// dispose. No `attach()` — no DOM view — but `set_model` still builds the
/// tokenized doc, view model, render frame, and cursor context synchronously.
///
/// The font is pinned (the macOS defaults) rather than platform-derived:
/// `editor_font_defaults`/`golden_line_height_ratio` differ per host OS
/// (12px/1.5 on macOS, 14px/1.35 elsewhere → line height 18 vs 19), and the
/// layout tests assert absolute pixel offsets. Monaco's testCodeEditor
/// likewise runs over a fixed `TestConfiguration`, not the host font.
fn with_test_viewer(
  text : String,
  body : (Viewer) -> Unit raise,
  options? : ViewerOptions = ViewerOptions(font_size=12, line_height=18),
) -> Unit raise {
  let viewer = Viewer::Viewer(options~) // NOTE: deliberately no attach()
  viewer.set_model(Some(test_model(text)))
  body(viewer)
  viewer.dispose()
}

///|
/// Installs the smallest DOM/runtime surface needed for a real attached View.
/// Timers are held until the Viewer has disposed; the fixture then drains any
/// uncancelled callback (notably the deferred squiggly-theme read) while the
/// fake DOM is still live and restores every global synchronously.
extern "js" fn install_mounted_test_browser() -> Unit =
  #| () => {
  #|   const depth = globalThis.__mountedTestBrowserDepth ?? 0;
  #|   globalThis.__mountedTestBrowserDepth = depth + 1;
  #|   if (depth > 0) return;
  #|   const voidTags = new Set([
  #|     "AREA", "BASE", "BR", "COL", "EMBED", "HR", "IMG", "INPUT",
  #|     "LINK", "META", "PARAM", "SOURCE", "TRACK", "WBR",
  #|   ]);
  #|   const decode = (value) => value
  #|     .replaceAll("&quot;", "\"")
  #|     .replaceAll("&#39;", "'")
  #|     .replaceAll("&lt;", "<")
  #|     .replaceAll("&gt;", ">")
  #|     .replaceAll("&amp;", "&");
  #|   const selectorMatches = (element, selector) => {
  #|     const value = selector.trim();
  #|     if (value.startsWith("[") && value.endsWith("]")) {
  #|       const body = value.slice(1, -1);
  #|       const equals = body.indexOf("=");
  #|       if (equals >= 0) {
  #|         const name = body.slice(0, equals);
  #|         const expected = body.slice(equals + 1).replace(/^"|"$/g, "");
  #|         return element.getAttribute(name) === expected;
  #|       }
  #|       return element.getAttribute(body) !== null;
  #|     }
  #|     if (value.startsWith(".")) {
  #|       return (element.getAttribute("class") || "")
  #|         .split(" ").filter(Boolean).includes(value.slice(1));
  #|     }
  #|     return value === "*" || element.nodeName === value.toUpperCase();
  #|   };
  #|   class MountedTestElement extends EventTarget {
  #|     constructor(tag = "div", ownerDocument = null) {
  #|       super();
  #|       this.nodeType = 1;
  #|       this.nodeName = tag.toUpperCase();
  #|       this.attributes = new Map();
  #|       this.childNodes = [];
  #|       this.parentNode = null;
  #|       this.ownerDocument = ownerDocument;
  #|       this.style = {
  #|         setProperty(name, value) { this[name] = value; },
  #|       };
  #|       this.scrollTop = 0;
  #|       this.scrollLeft = 0;
  #|       this.scrollWidth = 1000;
  #|       this.scrollHeight = 1000;
  #|       this.clientWidth = 100;
  #|       this.clientHeight = 100;
  #|       this.__scrollIntoView = null;
  #|       if (this.nodeName === "TEMPLATE") {
  #|         this.content = new MountedTestFragment(ownerDocument);
  #|       }
  #|     }
  #|     get children() {
  #|       return this.childNodes.filter((node) => node.nodeType === 1);
  #|     }
  #|     setAttribute(name, value) { this.attributes.set(name, String(value)); }
  #|     getAttribute(name) { return this.attributes.get(name) ?? null; }
  #|     hasAttribute(name) { return this.attributes.has(name); }
  #|     removeAttribute(name) { this.attributes.delete(name); }
  #|     insertBefore(child, reference) {
  #|       if (!reference) return this.appendChild(child);
  #|       if (child.parentNode) child.parentNode.removeChild(child);
  #|       const index = this.childNodes.indexOf(reference);
  #|       if (index < 0) return this.appendChild(child);
  #|       this.childNodes.splice(index, 0, child);
  #|       child.parentNode = this;
  #|       return child;
  #|     }
  #|     closest(selector) {
  #|       let node = this;
  #|       while (node && node.nodeType === 1) {
  #|         if (selectorMatches(node, selector)) return node;
  #|         node = node.parentNode;
  #|       }
  #|       return null;
  #|     }
  #|     appendChild(child) {
  #|       if (child.parentNode) child.parentNode.removeChild(child);
  #|       this.childNodes.push(child);
  #|       child.parentNode = this;
  #|       return child;
  #|     }
  #|     removeChild(child) {
  #|       this.childNodes = this.childNodes.filter((item) => item !== child);
  #|       child.parentNode = null;
  #|       return child;
  #|     }
  #|     replaceChildren(...children) {
  #|       for (const child of this.childNodes) child.parentNode = null;
  #|       this.childNodes = [];
  #|       for (const child of children) {
  #|         if (child?.nodeType === 11) {
  #|           for (const nested of Array.from(child.childNodes)) {
  #|             this.appendChild(nested);
  #|           }
  #|           child.childNodes = [];
  #|         } else {
  #|           this.appendChild(child);
  #|         }
  #|       }
  #|     }
  #|     querySelectorAll(selector) {
  #|       const selectors = selector.split(",");
  #|       const result = [];
  #|       const visit = (node) => {
  #|         for (const child of node.childNodes || []) {
  #|           if (
  #|             child.nodeType === 1 &&
  #|             selectors.some((value) => selectorMatches(child, value))
  #|           ) result.push(child);
  #|           visit(child);
  #|         }
  #|       };
  #|       visit(this);
  #|       return result;
  #|     }
  #|     querySelector(selector) {
  #|       return this.querySelectorAll(selector)[0] || null;
  #|     }
  #|     contains(child) {
  #|       if (child === this) return true;
  #|       return this.childNodes.some((node) =>
  #|         typeof node.contains === "function" && node.contains(child));
  #|     }
  #|     remove() {
  #|       if (this.parentNode) this.parentNode.removeChild(this);
  #|     }
  #|     focus() {
  #|       if (this.ownerDocument) this.ownerDocument.activeElement = this;
  #|       this.dispatchEvent(new Event("focus"));
  #|     }
  #|     blur() {
  #|       if (this.ownerDocument?.activeElement === this) {
  #|         this.ownerDocument.activeElement = null;
  #|       }
  #|       this.dispatchEvent(new Event("blur"));
  #|     }
  #|     scrollIntoView(options) { this.__scrollIntoView = options || true; }
  #|     set innerHTML(value) {
  #|       parseInto(
  #|         this.nodeName === "TEMPLATE" ? this.content : this,
  #|         value,
  #|         this.ownerDocument,
  #|       );
  #|     }
  #|     get textContent() {
  #|       return this.childNodes.map((child) => child.textContent || "").join("");
  #|     }
  #|     getBoundingClientRect() {
  #|       return {
  #|         x: 0, y: 0, left: 0, top: 0,
  #|         right: 100, bottom: 100, width: 100, height: 100,
  #|       };
  #|     }
  #|     getClientRects() { return [this.getBoundingClientRect()]; }
  #|   }
  #|   class MountedTestFragment {
  #|     constructor(ownerDocument) {
  #|       this.nodeType = 11;
  #|       this.nodeName = "#document-fragment";
  #|       this.ownerDocument = ownerDocument;
  #|       this.parentNode = null;
  #|       this.childNodes = [];
  #|     }
  #|     appendChild(child) {
  #|       child.parentNode?.removeChild?.(child);
  #|       this.childNodes.push(child);
  #|       child.parentNode = this;
  #|       return child;
  #|     }
  #|     removeChild(child) {
  #|       this.childNodes = this.childNodes.filter((item) => item !== child);
  #|       child.parentNode = null;
  #|       return child;
  #|     }
  #|     replaceChildren() {
  #|       for (const child of this.childNodes) child.parentNode = null;
  #|       this.childNodes = [];
  #|     }
  #|     querySelectorAll(selector) {
  #|       const holder = new MountedTestElement("div", this.ownerDocument);
  #|       holder.childNodes = this.childNodes;
  #|       return holder.querySelectorAll(selector);
  #|     }
  #|   }
  #|   class MountedTestText {
  #|     constructor(ownerDocument, value) {
  #|       this.nodeType = 3;
  #|       this.nodeName = "#text";
  #|       this.nodeValue = String(value);
  #|       this.parentNode = null;
  #|       this.ownerDocument = ownerDocument;
  #|     }
  #|     get textContent() { return this.nodeValue; }
  #|   }
  #|   const parseInto = (root, html, ownerDocument) => {
  #|     root.replaceChildren();
  #|     const stack = [root];
  #|     const tokens =
  #|       html.match(/<!--[\s\S]*?-->|<\/?[A-Za-z][^>]*>|[^<]+/g) || [];
  #|     for (const token of tokens) {
  #|       if (token.startsWith("<!--")) continue;
  #|       if (!token.startsWith("<")) {
  #|         stack.at(-1).appendChild(
  #|           new MountedTestText(ownerDocument, decode(token)),
  #|         );
  #|         continue;
  #|       }
  #|       if (token.startsWith("</")) {
  #|         if (stack.length > 1) stack.pop();
  #|         continue;
  #|       }
  #|       const open =
  #|         token.match(/^<([A-Za-z][A-Za-z0-9-]*)([\s\S]*?)\/?\s*>$/);
  #|       if (!open) continue;
  #|       const element = ownerDocument.createElement(open[1]);
  #|       const pattern =
  #|         /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  #|       let match;
  #|       while ((match = pattern.exec(open[2]))) {
  #|         element.setAttribute(
  #|           match[1],
  #|           decode(match[2] ?? match[3] ?? match[4] ?? ""),
  #|         );
  #|       }
  #|       stack.at(-1).appendChild(element);
  #|       if (!voidTags.has(element.nodeName) && !token.endsWith("/>")) {
  #|         stack.push(element);
  #|       }
  #|     }
  #|   };
  #|   globalThis.__mountedTestOriginalDocument = globalThis.document;
  #|   globalThis.__mountedTestOriginalElement = globalThis.Element;
  #|   globalThis.__mountedTestOriginalRequestAnimationFrame =
  #|     globalThis.requestAnimationFrame;
  #|   globalThis.__mountedTestOriginalCancelAnimationFrame =
  #|     globalThis.cancelAnimationFrame;
  #|   globalThis.__mountedTestOriginalGetComputedStyle =
  #|     globalThis.getComputedStyle;
  #|   globalThis.__mountedTestOriginalSetTimeout = globalThis.setTimeout;
  #|   globalThis.__mountedTestOriginalClearTimeout = globalThis.clearTimeout;
  #|   globalThis.__mountedTestFrameNextId = 1;
  #|   globalThis.__mountedTestFrames = new Map();
  #|   globalThis.__mountedTestTimerNextId = 1;
  #|   globalThis.__mountedTestTimers = new Map();
  #|   const ownerDocument = new EventTarget();
  #|   ownerDocument.nodeType = 9;
  #|   ownerDocument.defaultView = globalThis;
  #|   ownerDocument.activeElement = null;
  #|   ownerDocument.body = new MountedTestElement("body", ownerDocument);
  #|   ownerDocument.createElement = (tag) =>
  #|     new MountedTestElement(tag, ownerDocument);
  #|   ownerDocument.createTextNode = (value) =>
  #|     new MountedTestText(ownerDocument, value);
  #|   globalThis.document = ownerDocument;
  #|   globalThis.Element = MountedTestElement;
  #|   globalThis.requestAnimationFrame = (callback) => {
  #|     const id = globalThis.__mountedTestFrameNextId++;
  #|     globalThis.__mountedTestFrames.set(id, callback);
  #|     return id;
  #|   };
  #|   globalThis.cancelAnimationFrame = (id) => {
  #|     globalThis.__mountedTestFrames.delete(id);
  #|   };
  #|   globalThis.getComputedStyle = () => ({
  #|     getPropertyValue: () => "",
  #|   });
  #|   globalThis.setTimeout = (callback, _ms) => {
  #|     const id = globalThis.__mountedTestTimerNextId++;
  #|     globalThis.__mountedTestTimers.set(id, callback);
  #|     return id;
  #|   };
  #|   globalThis.clearTimeout = (id) => {
  #|     globalThis.__mountedTestTimers.delete(id);
  #|   };
  #| }

///|
extern "js" fn restore_mounted_test_browser() -> Unit =
  #| () => {
  #|   const depth = globalThis.__mountedTestBrowserDepth ?? 0;
  #|   if (depth === 0) return;
  #|   globalThis.__mountedTestBrowserDepth = depth - 1;
  #|   if (depth > 1) return;
  #|   while (globalThis.__mountedTestFrames.size > 0) {
  #|     const pending = Array.from(globalThis.__mountedTestFrames.values());
  #|     globalThis.__mountedTestFrames.clear();
  #|     for (const callback of pending) callback(0);
  #|   }
  #|   while (globalThis.__mountedTestTimers.size > 0) {
  #|     const pending = Array.from(globalThis.__mountedTestTimers.values());
  #|     globalThis.__mountedTestTimers.clear();
  #|     for (const callback of pending) callback();
  #|   }
  #|   const restore = (name, value) => {
  #|     if (value === undefined) {
  #|       delete globalThis[name];
  #|     } else {
  #|       globalThis[name] = value;
  #|     }
  #|   };
  #|   restore("document", globalThis.__mountedTestOriginalDocument);
  #|   restore("Element", globalThis.__mountedTestOriginalElement);
  #|   restore(
  #|     "requestAnimationFrame",
  #|     globalThis.__mountedTestOriginalRequestAnimationFrame,
  #|   );
  #|   restore(
  #|     "cancelAnimationFrame",
  #|     globalThis.__mountedTestOriginalCancelAnimationFrame,
  #|   );
  #|   restore("getComputedStyle", globalThis.__mountedTestOriginalGetComputedStyle);
  #|   restore("setTimeout", globalThis.__mountedTestOriginalSetTimeout);
  #|   restore("clearTimeout", globalThis.__mountedTestOriginalClearTimeout);
  #|   delete globalThis.__mountedTestOriginalDocument;
  #|   delete globalThis.__mountedTestOriginalElement;
  #|   delete globalThis.__mountedTestOriginalRequestAnimationFrame;
  #|   delete globalThis.__mountedTestOriginalCancelAnimationFrame;
  #|   delete globalThis.__mountedTestOriginalGetComputedStyle;
  #|   delete globalThis.__mountedTestOriginalSetTimeout;
  #|   delete globalThis.__mountedTestOriginalClearTimeout;
  #|   delete globalThis.__mountedTestFrameNextId;
  #|   delete globalThis.__mountedTestFrames;
  #|   delete globalThis.__mountedTestTimerNextId;
  #|   delete globalThis.__mountedTestTimers;
  #|   delete globalThis.__mountedTestBrowserDepth;
  #| }

///|
extern "js" fn flush_mounted_test_frames() -> Unit =
  #| () => {
  #|   while (globalThis.__mountedTestFrames.size > 0) {
  #|     const pending = Array.from(globalThis.__mountedTestFrames.values());
  #|     globalThis.__mountedTestFrames.clear();
  #|     for (const callback of pending) callback(0);
  #|   }
  #| }

///|
extern "js" fn run_one_mounted_test_frame() -> Unit =
  #| () => {
  #|   if (globalThis.__mountedTestFrames.size === 0) {
  #|     throw new Error("expected one pending mounted-test frame");
  #|   }
  #|   const pending = Array.from(globalThis.__mountedTestFrames.values());
  #|   globalThis.__mountedTestFrames.clear();
  #|   for (const callback of pending) callback(0);
  #| }

///|
extern "js" fn mounted_test_frame_count() -> Int =
  #| () => globalThis.__mountedTestFrames.size

///|
extern "js" fn mounted_test_child_count(element : @rdom.Element) -> Int =
  #| (element) => element.childNodes.length

///|
extern "js" fn set_mounted_test_client_size(
  element : @rdom.Element,
  width : Double,
  height : Double,
) -> Unit =
  #| (element, width, height) => {
  #|   element.clientWidth = width;
  #|   element.clientHeight = height;
  #| }

///|
extern "js" fn same_mounted_test_element(
  left : @rdom.Element,
  right : @rdom.Element,
) -> Bool =
  #| (left, right) => left === right

///|
extern "js" fn mounted_test_node_value(node : @rdom.Element) -> String =
  #| (node) => node.nodeValue ?? ""

///|
/// Attached counterpart of `with_test_viewer`. The native frame queue is held,
/// so tests can inspect the browser bundle's pending render/reveal state before
/// a DOM flush consumes it.
fn with_mounted_test_viewer(
  text : String,
  body : (Viewer) -> Unit raise,
  options? : ViewerOptions = ViewerOptions(font_size=12, line_height=18),
) -> Unit raise {
  install_mounted_test_browser()
  defer restore_mounted_test_browser()
  let viewer = Viewer::Viewer(options~)
  defer viewer.dispose()
  let host = @rdom.document().create_element("div")
  viewer.attach(host)
  viewer.set_model(Some(test_model(text)))
  body(viewer)
}

///|
/// `ITestCodeEditor.getViewModel()` — whitebox read of the private field.
fn Viewer::test_view_model(self : Viewer) -> @view_model.ViewModel {
  self.get_view_model().unwrap()
}

///|
/// `ITestCodeEditor`'s cursor read — the view model's always-present
/// controller (`viewModelImpl.ts:124`).
fn Viewer::test_cursor(self : Viewer) -> @cursor.CursorsController {
  self.test_view_model().cursor
}

///|
/// The clamped view-line window the viewer would render for the layout's
/// current visible window — the headless analog of `synced_window`, which
/// only runs inside a DOM flush.
fn Viewer::test_window(self : Viewer) -> @view_layout.LineWindow {
  let view_model = self.test_view_model()
  view_model.clamp_window(view_model.view_layout.visible_window())
}

///|
/// Forces a soft-wrap column and reflows the view model, the headless analog
/// of the wrap width an attached viewer derives from its measured content box.
/// `ViewerOptions` carries no wrap-column field (the real column is measured
/// from the DOM via `soft_wrap_column_for_content_width`), so a headless wrap
/// test sets the private column directly. Requires `options.soft_wrap`.
fn Viewer::test_set_soft_wrap_column(self : Viewer, column : Int) -> Unit {
  self.configuration.commit_soft_wrap_column(column) |> ignore
  self.on_configuration_changed()
}

///|
/// Sets the viewport box the layout windows against, the headless analog of the
/// measured content box, so frame-windowing can be tested without a DOM.
fn Viewer::test_set_viewport(
  self : Viewer,
  width~ : Double,
  height~ : Double,
) -> Unit {
  self.configuration.commit_measured_size(width, height)
  let configuration = self.configuration.snapshot()
  match self.get_view_model() {
    Some(view_model) =>
      view_model.view_layout.set_viewport_size(
        width=configuration.content_width,
        height=configuration.height,
      )
      |> ignore
    None => ()
  }
}

///|
/// A document of `line_count` distinct one-line entries, for windowing tests.
fn long_document(line_count : Int) -> String {
  let out = StringBuilder()
  for i in 0..<line_count {
    if i > 0 {
      out.write_char('\n')
    }
    out <+ "line \{i}"
  }
  out.to_string()
}

///|
/// Component-wise position equality. `@base_common.Position` derives `Eq`/`Debug`
/// but not `Show`, so `assert_eq` on it cannot format a failure message; the
/// rest of this package's tests compare `line_number`/`column` (both `Int`,
/// which has `Show`) the same way.
fn assert_position(
  actual : @base_common.Position,
  expected : @base_common.Position,
) -> Unit raise {
  assert_eq(actual.line_number, expected.line_number)
  assert_eq(actual.column, expected.column)
}

///|
/// Selection equality by endpoints (anchor + active), for the same `Show` reason
/// as `assert_position`.
fn assert_selection_eq(
  actual : @core.Selection,
  expected : @core.Selection,
) -> Unit raise {
  assert_position(actual.get_selection_start(), expected.get_selection_start())
  assert_position(actual.get_position(), expected.get_position())
}

///|
/// `assertCursor`: compare the controller's model selection to an expected one.
fn assert_cursor(viewer : Viewer, expected : @core.Selection) -> Unit raise {
  assert_selection_eq(viewer.test_cursor().get_model_selection(), expected)
}

///|
