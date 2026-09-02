import { expect, test } from '../support/test.js';
import { workspaceItem as workspaceSelector } from '../support/app.js';

const sourceEditor =
  '.code-viewer-host > .monaco-editor.readonly-editor';
const markdownDocument =
  '.markdown-viewer-host > .moonbit-viewer-markdown-document';
const diffEditor = '.diff-editor-host > .moonbit-diff-editor';

// Proves the public embedding boundary: a code-only Viewer, an explicit
// MarkdownViewer, a first-class DiffEditor, and the file tree all run against
// in-memory providers without opening a websocket.
test('runs the independent viewer surfaces and tree without a server', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  const websockets = [];
  page.on('websocket', (ws) => websockets.push(ws.url()));

  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator('.editor-shell')).toHaveAttribute(
    'data-source-presentation',
    'code',
  );
  await expect(page.locator(sourceEditor)).toContainText('fn main');
  await expect
    .poll(async () => (await page.locator('.embedded-viewer-stack').boundingBox())?.width ?? 0)
    .toBeGreaterThan(900);

  // Language highlighting is registered by the embedding host, not fetched
  // from a workbench or server.
  await expect(page.locator('.mtk3', { hasText: 'fn' }).first()).toBeVisible();
  await expect(page.locator(workspaceItem('src'))).toHaveAttribute('aria-expanded', 'true');
  await expect(page.locator(workspaceItem('src/main.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );

  const diffToggle = page.locator('[data-action="toggle-diff"]');
  const layoutToggle = page.locator('[data-action="toggle-diff-layout"]');
  await expect(layoutToggle).toBeDisabled();
  await expect(layoutToggle).toHaveAccessibleName('Inline diff layout');
  await expect(diffToggle).toHaveAccessibleName('Full diff');
  await diffToggle.click();

  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  await expect(diff).toBeVisible();
  await expect(diff).toHaveAttribute('role', 'region');
  await expect(diff).toHaveAccessibleName('File comparison');
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(originalPane).toHaveAttribute('role', 'group');
  await expect(originalPane).toHaveAccessibleName('Original file');
  await expect(modifiedPane).toHaveAttribute('role', 'group');
  await expect(modifiedPane).toHaveAccessibleName('Modified file');
  await expect(originalPane.locator('.monaco-editor')).toContainText(
    'println("hello")',
  );
  await expect(modifiedPane.locator('.monaco-editor')).toContainText(
    'println(greeting())',
  );
  await expect(originalPane.locator('.diff-editor-line-delete')).toHaveCount(1);
  await expect(modifiedPane.locator('.diff-editor-line-insert')).toHaveCount(1);
  const deleteGutter = originalPane.locator('.cmdr.diff-editor-gutter-delete').first();
  const insertGutter = modifiedPane.locator('.cmdr.diff-editor-gutter-insert').first();
  const deleteSign = originalPane.locator(
    '.cldr.delete-sign.codicon-diff-remove',
  ).first();
  const insertSign = modifiedPane.locator(
    '.cldr.insert-sign.codicon-diff-insert',
  ).first();
  await expect(deleteGutter).toBeVisible();
  await expect(insertGutter).toBeVisible();
  await expect(deleteSign).toBeVisible();
  await expect(insertSign).toBeVisible();
  expect(
    await deleteSign.evaluate((node) => getComputedStyle(node, '::before').content),
  ).toBe('"\ueb3b"');
  expect(
    await insertSign.evaluate((node) => getComputedStyle(node, '::before').content),
  ).toBe('"\uea60"');

  // Algorithm controls are a host/provider concern. DiffEditor itself contains
  // neither the removed toolbar nor the host-owned layout action.
  await expect(diff.locator('.moonbit-diff-editor-toolbar')).toHaveCount(0);
  await expect(diff.locator('[data-action="toggle-diff-layout"]')).toHaveCount(0);

  await expect(layoutToggle).toBeEnabled();
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'false');
  await layoutToggle.click();
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'true');
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(originalPane).toBeVisible();
  await expect(originalPane).not.toHaveAttribute('aria-hidden', 'true');
  await expect(modifiedPane).toHaveAccessibleName('Modified file');
  const inlineGeometry = await diff.evaluate((root) => {
    const original = root.querySelector('.moonbit-diff-editor-original');
    const modified = root.querySelector('.moonbit-diff-editor-modified');
    const originalRect = original.getBoundingClientRect();
    const modifiedRect = modified.getBoundingClientRect();
    return {
      stripWidth: Number(root.getAttribute('data-inline-original-width')),
      originalWidth: originalRect.width,
      originalRight: originalRect.right,
      modifiedLeft: modifiedRect.left,
      originalVisibility: getComputedStyle(original).visibility,
      originalPointerEvents: getComputedStyle(original).pointerEvents,
    };
  });
  expect(inlineGeometry.stripWidth).toBeGreaterThan(5);
  expect(Math.abs(inlineGeometry.originalWidth - inlineGeometry.stripWidth)).toBeLessThanOrEqual(1);
  expect(Math.abs(inlineGeometry.originalRight - inlineGeometry.modifiedLeft)).toBeLessThanOrEqual(1);
  expect(inlineGeometry.originalVisibility).toBe('visible');
  expect(inlineGeometry.originalPointerEvents).not.toBe('none');

  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(originalPane).toBeVisible();
  await expect(modifiedPane).toHaveAccessibleName('Modified file');

  await diffToggle.click();
  await expect(diff).toBeHidden();
  await expect(page.locator(sourceEditor)).toContainText('fn main');

  // Nested folders resolve lazily on expand.
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toHaveCount(0);
  await page.locator(workspaceItem('src/lib')).click();
  await expect(page.locator(workspaceItem('src/lib'))).toHaveAttribute(
    'aria-expanded',
    'true',
  );
  await page.locator(workspaceItem('src/lib/util.mbt')).click();
  await expect(page.locator(sourceEditor)).toContainText('util_answer');
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );

  // Markdown routing is explicit at the host. The code Viewer is detached and
  // hidden while the independent MarkdownViewer owns this source model.
  await page.locator(workspaceItem('README.md')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator('.editor-shell')).toHaveAttribute(
    'data-source-presentation',
    'markdown',
  );
  await expect(page.locator('.code-viewer-host')).toBeHidden();
  await expect(page.locator('.markdown-viewer-host')).toBeVisible();
  const markdown = page.locator(markdownDocument);
  await expect(markdown).toBeVisible();
  await expect(markdown).toHaveAttribute(
    'data-source-uri',
    'memory://workspace/README.md',
  );
  await expect(markdown.locator('h1')).toHaveText('Embedded Markdown document');
  await expect(markdown.locator('strong')).toHaveText('MarkdownViewer');

  // Presentation and MoonBit Markdown resource-kind routing use a decoded,
  // lowercase path rather than case-sensitive suffix checks.
  await page.locator(workspaceItem('Guide.MD')).click();
  await expect(markdown).toHaveAttribute(
    'data-source-uri',
    'memory://workspace/Guide.MD',
  );
  await expect(markdown.locator('h1')).toHaveText('Uppercase Markdown');
  await page.locator(workspaceItem('tour.MBT.MD')).click();
  await expect(markdown).toHaveAttribute(
    'data-source-uri',
    'memory://workspace/tour.MBT.MD',
  );
  await expect(markdown.locator('[data-markdown-semantic="moonbit-check"]')).toHaveCount(1);

  expect(websockets).toEqual([]);
});

test('reserves the overview rail and switches at the root 900/901 boundary', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const stack = page.locator('.embedded-viewer-stack');
  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const sash = diff.getByRole('separator', { name: 'Resize diff panes' });
  const layoutToggle = page.locator('[data-action="toggle-diff-layout"]');

  await setViewerStackWidth(stack, diff, 901);
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(originalPane).toBeVisible();
  await expect(sash).toBeVisible();
  await expect(sash).toHaveAttribute('aria-valuemin', '10');
  await expect(sash).toHaveAttribute('aria-valuemax', '90');
  await expect(sash).toHaveAttribute('aria-valuenow', '50');

  await setViewerStackWidth(stack, diff, 900);
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(originalPane).toBeVisible();
  await expect(originalPane).not.toHaveAttribute('aria-hidden', 'true');
  await expect(sash).toBeHidden();

  // Responsive fallback never mutates the requested SideBySide preference.
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'false');
  await setViewerStackWidth(stack, diff, 901);
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');

  // Explicit Inline remains Inline even when the host grows above the boundary.
  await layoutToggle.click();
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'true');
  await setViewerStackWidth(stack, diff, 1000);
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(originalPane).toBeVisible();
});

test('synchronizes both SideBySide scroll axes without clamp feedback', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('scroll-sync.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const originalScrollable = originalPane.locator(
    '.monaco-scrollable-element.editor-scrollable',
  );
  const modifiedScrollable = modifiedPane.locator(
    '.monaco-scrollable-element.editor-scrollable',
  );
  const layoutToggle = page.locator('[data-action="toggle-diff-layout"]');
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(originalPane.locator('.view-lines')).toContainText('scroll_stable_0');
  await expect(modifiedPane.locator('.view-lines')).toContainText('scroll_stable_0');
  await expect
    .poll(async () => {
      const state = await diffScrollState(diff);
      return state.original.scrollWidth - state.modified.scrollWidth;
    })
    .toBeGreaterThan(5_000);

  // Original -> modified vertical synchronization.
  await originalScrollable.hover();
  await page.mouse.wheel(0, 720);
  await expect
    .poll(async () => (await diffScrollState(diff)).original.top)
    .toBeGreaterThan(200);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'top'))
    .toBeLessThanOrEqual(1);
  const afterOriginalVertical = await diffScrollState(diff);

  // Modified -> original vertical synchronization.
  await modifiedScrollable.hover();
  await page.mouse.wheel(0, 540);
  await expect
    .poll(async () => (await diffScrollState(diff)).modified.top)
    .toBeGreaterThan(afterOriginalVertical.modified.top + 100);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'top'))
    .toBeLessThanOrEqual(1);

  // Original -> modified horizontal synchronization inside their shared
  // range, followed by the reverse direction.
  await originalScrollable.hover();
  await page.mouse.wheel(360, 0);
  await expect
    .poll(async () => (await diffScrollState(diff)).original.left)
    .toBeGreaterThan(100);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'left'))
    .toBeLessThanOrEqual(1);
  const afterOriginalHorizontal = await diffScrollState(diff);

  await modifiedScrollable.hover();
  await page.mouse.wheel(280, 0);
  await expect
    .poll(async () => (await diffScrollState(diff)).modified.left)
    .toBeGreaterThan(afterOriginalHorizontal.modified.left + 50);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'left'))
    .toBeLessThanOrEqual(1);

  // The original has a much wider scroll plane. When its requested position
  // exceeds the modified maximum, the target clamps locally; that target-side
  // scroll event must not echo back and pull the original to the smaller max.
  const beforeClamp = await diffScrollState(diff);
  await originalScrollable.hover();
  await page.mouse.wheel(50_000, 0);
  await expect
    .poll(async () => {
      const state = await diffScrollState(diff);
      return state.original.left - state.modified.maxLeft;
    })
    .toBeGreaterThan(1_000);
  await expect
    .poll(async () => {
      const state = await diffScrollState(diff);
      return Math.abs(state.modified.left - state.modified.maxLeft);
    })
    .toBeLessThanOrEqual(1);
  const clamped = await diffScrollState(diff);
  expect(clamped.original.left).toBeGreaterThan(beforeClamp.original.left);
  expect(clamped.original.left).toBeGreaterThan(clamped.modified.left + 1_000);
  await settleAnimationFrames(page, 3);
  const settled = await diffScrollState(diff);
  expect(Math.abs(settled.original.left - clamped.original.left)).toBeLessThanOrEqual(1);
  expect(Math.abs(settled.modified.left - clamped.modified.left)).toBeLessThanOrEqual(1);

  // Inline retains both live kernels, so the same two-axis contract applies
  // even though the original is clipped to its dynamic line-number strip.
  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await modifiedScrollable.hover();
  await page.mouse.wheel(-50_000, -50_000);
  await expect
    .poll(async () => {
      const state = await diffScrollState(diff);
      return Math.max(
        state.original.top,
        state.modified.top,
        state.original.left,
        state.modified.left,
      );
    })
    .toBeLessThanOrEqual(1);

  // Modified -> original in Inline.
  await page.mouse.wheel(0, 520);
  await page.mouse.wheel(4, 0);
  await expect
    .poll(async () => (await diffScrollState(diff)).modified.top)
    .toBeGreaterThan(150);
  await expect
    .poll(async () => (await diffScrollState(diff)).modified.left)
    .toBeGreaterThan(1);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'top'))
    .toBeLessThanOrEqual(1);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'left'))
    .toBeLessThanOrEqual(1);
  const afterInlineModified = await diffScrollState(diff);

  // Original -> modified in Inline through the visible old-number strip.
  await originalPane.hover({ position: { x: 2, y: 80 } });
  await page.mouse.wheel(0, 360);
  await page.mouse.wheel(4, 0);
  await expect
    .poll(async () => (await diffScrollState(diff)).original.top)
    .toBeGreaterThan(afterInlineModified.original.top + 80);
  await expect
    .poll(async () => (await diffScrollState(diff)).original.left)
    .toBeGreaterThan(afterInlineModified.original.left + 1);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'top'))
    .toBeLessThanOrEqual(1);
  await expect
    .poll(async () => scrollAxisDelta(diff, 'left'))
    .toBeLessThanOrEqual(1);
});

test('keeps identical files fully visible without diff decoration or overlay', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('identical.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(originalPane.locator('.view-lines')).toContainText('identical_fixture');
  await expect(originalPane.locator('.view-lines')).toContainText('unchanged = 42');
  await expect(modifiedPane.locator('.view-lines')).toContainText('identical_fixture');
  await expect(modifiedPane.locator('.view-lines')).toContainText('unchanged = 42');
  await expectNoDiffPresentation(diff);

  await page.locator('[data-action="toggle-diff-layout"]').click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(originalPane).toBeVisible();
  await expect(modifiedPane.locator('.view-lines')).toContainText('unchanged = 42');
  await expectNoDiffPresentation(diff);
});

test('removes a disabled sash from visibility, tab order, and key handling', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const sash = diff.locator('.moonbit-diff-editor-sash');
  const toggle = page.locator('[data-action="toggle-diff-sash"]');
  await expect(sash).toBeVisible();
  await expect(sash).toHaveAttribute('tabindex', '0');
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');

  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await expect(sash).toBeHidden();
  await expect(sash).toHaveAttribute('aria-hidden', 'true');
  expect(await sash.getAttribute('tabindex')).toBeNull();
  expect(
    await sash.evaluate((node) => {
      const event = new KeyboardEvent('keydown', {
        key: 'ArrowRight',
        bubbles: true,
        cancelable: true,
      });
      node.dispatchEvent(event);
      return event.defaultPrevented;
    }),
  ).toBe(false);

  await toggle.click();
  await expect(sash).toBeVisible();
  await expect(sash).not.toHaveAttribute('aria-hidden', 'true');
  await expect(sash).toHaveAttribute('tabindex', '0');
});

test('keeps original focus in Inline and keeps F7 navigation live', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('navigation-anchors.mbt')).click();
  await page.locator('[data-action="toggle-diff"]').click();

  const stack = page.locator('.embedded-viewer-stack');
  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const liveRegion = diff.locator('.moonbit-diff-editor-live-region');
  await originalPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
  await expect
    .poll(() =>
      originalPane.evaluate((node) => node.contains(document.activeElement)),
    )
    .toBe(true);
  await expect(
    originalPane.locator('.line-numbers.active-line-number'),
  ).toHaveCount(1);

  // Responsive layout changes do not move focus through a toolbar button.
  await setViewerStackWidth(stack, diff, 900);
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect
    .poll(() =>
      originalPane.evaluate((node) => node.contains(document.activeElement)),
    )
    .toBe(true);
  // VS Code resolves the accessible F7 group from the modified cursor, not
  // from a separate navigation index. The fixture keeps the groups at the
  // exact six-line non-merging boundary.
  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(
    'Change 2 of 2; original insertion anchor at line 10; modified lines 9 through 9',
  );
});

test('reconciles height-only and Inline-to-side layouts after fresh pane renders', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('alignment-zones.mbt')).click();
  await page.locator('[data-action="toggle-diff"]').click();

  const stack = page.locator('.embedded-viewer-stack');
  const diff = page.locator(diffEditor);
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const layoutToggle = page.locator('[data-action="toggle-diff-layout"]');
  const spacers = diff.locator('.moonbit-diff-editor-alignment-spacer[monaco-view-zone]');
  await expect.poll(() => spacers.count()).toBeGreaterThan(0);
  const spacerPaint = await spacers.first().evaluate((node) => {
    const style = getComputedStyle(node);
    return {
      backgroundImage: style.backgroundImage,
      backgroundSize: style.backgroundSize,
    };
  });
  expect(spacerPaint.backgroundImage).toContain('linear-gradient');
  expect(spacerPaint.backgroundImage).not.toBe('none');
  expect(spacerPaint.backgroundSize).toBe('8px 8px');
  const beforeIds = await spacers.evaluateAll((nodes) =>
    nodes.map((node) => node.getAttribute('monaco-view-zone')),
  );

  // Width is unchanged: the new ids prove a fresh geometry transaction still
  // replaced the managed alignment zones after the height-only outer layout.
  await stack.evaluate((node) => {
    node.style.height = '620px';
    node.style.flex = '0 0 auto';
  });
  await expect
    .poll(async () =>
      spacers.evaluateAll((nodes) =>
        nodes.map((node) => node.getAttribute('monaco-view-zone')),
      ),
    )
    .not.toEqual(beforeIds);
  // The first diff is inside the rich Markdown block, so its hidden source
  // decoration is intentionally absent from the rendered line DOM. Compare
  // the first visible context line after that block instead.
  expect(
    await matchingCodeLineTopDelta(diff, 'let stable_21 = 21'),
  ).toBeLessThanOrEqual(1);

  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await modifiedPane.locator('.monaco-scrollable-element.editor-scrollable').hover();
  await page.mouse.wheel(0, 8_500);
  await expect
    .poll(async () => (await viewportCodeAnchor(modifiedPane))?.modelIndex ?? 0)
    .toBeGreaterThan(250);
  const beforeTransition = await viewportCodeAnchor(modifiedPane);
  expect(beforeTransition).not.toBeNull();

  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect.poll(() => spacers.count()).toBeGreaterThan(0);
  await expect
    .poll(async () => (await viewportCodeAnchor(modifiedPane))?.text)
    .toBe(beforeTransition.text);
  // Rich Markdown zones measure after their first pane paint. The modified
  // model anchor remains canonical through those follow-up ViewZone layouts,
  // not just through the synchronous layout toggle.
  await settleAnimationFrames(page, 3);
  const afterSide = await viewportCodeAnchor(modifiedPane);
  expect(afterSide.modelIndex).toBe(beforeTransition.modelIndex);
  expect(Math.abs(afterSide.offset - beforeTransition.offset)).toBeLessThanOrEqual(1);
  expect(await matchingCodeLineTopDelta(diff, beforeTransition.text)).toBeLessThanOrEqual(1);

  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect
    .poll(async () => (await viewportCodeAnchor(modifiedPane))?.text)
    .toBe(beforeTransition.text);
  await settleAnimationFrames(page, 3);
  const afterInline = await viewportCodeAnchor(modifiedPane);
  expect(afterInline.modelIndex).toBe(beforeTransition.modelIndex);
  expect(Math.abs(afterInline.offset - beforeTransition.offset)).toBeLessThanOrEqual(1);
  expect(await matchingCodeLineTopDelta(diff, beforeTransition.text)).toBeLessThanOrEqual(1);
});

test('navigates deletion and insertion anchors across side-by-side and Inline layouts', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('navigation-anchors.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const liveRegion = diff.locator('.moonbit-diff-editor-live-region');
  const layoutToggle = page.locator('[data-action="toggle-diff-layout"]');
  const deletionAnnouncement =
    'Change 1 of 2; original lines 3 through 3; modified deletion anchor at line 3';
  const insertionAnnouncement =
    'Change 2 of 2; original insertion anchor at line 10; modified lines 9 through 9';
  await expect(liveRegion).toHaveAttribute('aria-live', 'polite');
  await expect(liveRegion).toHaveAttribute('aria-atomic', 'true');
  await expect(originalPane.locator('.diff-editor-line-delete')).toHaveCount(1);
  await expect(modifiedPane.locator('.diff-editor-line-insert')).toHaveCount(1);

  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });

  // Cursor-relative navigation starts with the hunk after the clicked line.
  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(insertionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-modified')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);

  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(deletionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-modified')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);

  // Inline has one interactive surface. Consecutive F7 presses reveal both
  // kinds of hunk in the modified editor, including the deletion-only anchor.
  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(insertionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-modified')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);

  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(deletionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-modified')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);

  await page.keyboard.press('Shift+F7');
  await expect(liveRegion).toHaveText(insertionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-modified')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);
});

test('renders a 2600-line Inline deletion eagerly like VS Code', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('large.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  await expect(diff).toBeVisible();
  await expect(diff.locator('.moonbit-diff-editor-pane > .monaco-editor')).toHaveCount(2);
  await expect(diff.locator('.view-line').first()).toBeVisible();
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);

  await page.locator('[data-action="toggle-diff-layout"]').click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  const block = modifiedPane.locator('.diff-editor-inline-deleted-block');
  await expect(block).toHaveCount(1);
  await expect(block).toHaveAttribute('data-original-line-start', '1');
  await expect(block).toHaveAttribute('data-original-line-end-exclusive', '2601');

  const top = await inlineDeletedWindowEvidence(modifiedPane);
  expect(top.rowCount).toBe(2600);
  expect(top.firstLine).toBe(1);
  expect(top.lastLine).toBe(2600);
  expect(top.validText).toBeTruthy();
  expect(top.validMarkers).toBeTruthy();
  expect(top.hasForgedLineNumbers).toBeFalsy();
  expect(top.hasTokens).toBeTruthy();

  // A geometry refresh recreates the eager detached rendering and keeps the
  // complete source range, matching VS Code's renderLines behavior.
  await page.setViewportSize({ width: 1360, height: 900 });
  await expect
    .poll(async () => (await inlineDeletedWindowEvidence(modifiedPane)).rowCount)
    .toBe(2600);
});

test('eagerly renders every row across fragmented Inline deletions', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('fragmented-large.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();
  await page.locator('[data-action="toggle-diff-layout"]').click();

  const diff = page.locator(diffEditor);
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const blocks = modifiedPane.locator('.diff-editor-inline-deleted-block');
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(blocks).toHaveCount(20);

  // F7 follows VS Code's modified empty-anchor reveal without lazy rendering.
  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
  await page.keyboard.press('F7');
  await expect
    .poll(async () => (await fragmentedInlineEvidence(modifiedPane)).activeFragments)
    .toContain(0);
  const top = await fragmentedInlineEvidence(modifiedPane);
  expect(top.rowCount).toBe(2600);
  expect(top.activeBlockCount).toBe(20);
  expect(top.validText).toBeTruthy();
  expect(top.validMarkers).toBeTruthy();
  expect(top.hasForgedLineNumbers).toBeFalsy();
  expect(top.hasTokens).toBeTruthy();
  expect(top.activeOriginalLines).toContain(1);
  // The twentieth 130-line deletion spans original lines 2490..2619;
  // original line 2620 is its retained anchor and belongs to the code model.
  expect(top.activeOriginalLines).toContain(2619);
  expect(top.activeFragments).toHaveLength(20);
});

test('renders character changes and VS Code high-contrast diff paint', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('src/lib')).click();
  await page.locator(workspaceItem('src/lib/util.mbt')).click();
  await expect(page.locator(sourceEditor)).toContainText('42');
  await page.locator('[data-action="toggle-diff"]').click();

  const diff = page.locator(diffEditor);
  const originalPane = diff.locator('.moonbit-diff-editor-original');
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  const deletedCharacter = originalPane.locator('.diff-editor-char-delete');
  const insertedCharacter = modifiedPane.locator('.diff-editor-char-insert');
  const deletedLine = originalPane.locator('.diff-editor-line-delete');
  const insertedLine = modifiedPane.locator('.diff-editor-line-insert');
  const deletedGutter = originalPane.locator('.diff-editor-gutter-delete');
  const insertedGutter = modifiedPane.locator('.diff-editor-gutter-insert');
  const deleteSign = originalPane.locator('.delete-sign');
  const insertSign = modifiedPane.locator('.insert-sign');
  await expect(originalPane.locator('.view-lines')).toContainText('41');
  await expect(modifiedPane.locator('.view-lines')).toContainText('42');
  // VS Code renders `className` decorations as text-free DecorationsOverlay
  // rectangles (`cdr`), rather than wrapping the changed text in a span.
  await expect(deletedCharacter).toHaveCount(1);
  await expect(insertedCharacter).toHaveCount(1);
  await expect(deletedCharacter).toHaveClass(/\bcdr\b/);
  await expect(insertedCharacter).toHaveClass(/\bcdr\b/);
  await page.locator('.editor-shell').evaluate((node) => {
    node.setAttribute('data-theme', 'light');
  });
  const [deletedBackground, insertedBackground] = await Promise.all([
    deletedCharacter.evaluate((node) => getComputedStyle(node).backgroundColor),
    insertedCharacter.evaluate((node) => getComputedStyle(node).backgroundColor),
  ]);
  expect(deletedBackground).toBe('rgba(255, 0, 0, 0.2)');
  expect(insertedBackground).toBe('rgba(156, 204, 44, 0.25)');
  const [deletedBox, insertedBox] = await Promise.all([
    deletedCharacter.boundingBox(),
    insertedCharacter.boundingBox(),
  ]);
  expect(deletedBox?.width).toBeGreaterThan(0);
  expect(deletedBox?.height).toBeGreaterThan(0);
  expect(insertedBox?.width).toBeGreaterThan(0);
  expect(insertedBox?.height).toBeGreaterThan(0);
  await originalPane.locator('.monaco-editor').evaluate((node) => {
    node.setAttribute('data-theme', 'hc-black');
  });
  await modifiedPane.locator('.monaco-editor').evaluate((node) => {
    node.setAttribute('data-theme', 'hc-light');
  });
  await expect(deletedCharacter).toHaveCSS('border-color', 'rgb(255, 0, 143)');
  await expect(insertedCharacter).toHaveCSS('border-color', 'rgb(55, 78, 6)');
  await expect(deletedCharacter).toHaveCSS('border-width', '1px');
  await expect(insertedCharacter).toHaveCSS('border-width', '1px');
  await expect(deletedCharacter).toHaveCSS('border-style', 'dashed');
  await expect(insertedCharacter).toHaveCSS('border-style', 'dashed');
  await expect(deletedLine).toHaveCount(1);
  await expect(insertedLine).toHaveCount(1);
  for (const decoration of [
    deletedCharacter,
    insertedCharacter,
    deletedLine,
    insertedLine,
    deletedGutter,
    insertedGutter,
  ]) {
    await expect(decoration).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
  }
  expect(
    await deleteSign.evaluate(
      (node) => getComputedStyle(node, '::before').opacity,
    ),
  ).toBe('1');
  expect(
    await insertSign.evaluate(
      (node) => getComputedStyle(node, '::before').opacity,
    ),
  ).toBe('1');

  await page.locator('[data-action="toggle-diff-layout"]').click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await modifiedPane.locator('.monaco-editor').evaluate((node) => {
    node.setAttribute('data-theme', 'hc-black');
  });
  const inlineBlock = modifiedPane.locator('.diff-editor-inline-deleted-block');
  const inlineMargin = modifiedPane.locator('.diff-editor-inline-deleted-margin');
  const inlineDeletedLine = modifiedPane.locator('.diff-editor-inline-deleted-line');
  const inlineDeletedCharacter = modifiedPane.locator(
    '.diff-editor-inline-char-delete',
  );
  const inlineDeleteSign = modifiedPane.locator(
    '.diff-editor-inline-delete-sign',
  );
  await expect(inlineBlock).toHaveCount(1);
  await expect(inlineMargin).toHaveCount(1);
  for (const decoration of [
    inlineBlock,
    inlineMargin,
    inlineDeletedCharacter,
  ]) {
    await expect(decoration).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
  }
  await expect(inlineDeletedLine).toHaveCSS('border-style', 'dashed');
  await expect(inlineDeletedCharacter).toHaveCSS('border-style', 'dashed');
  expect(
    await inlineDeleteSign.evaluate(
      (node) => getComputedStyle(node, '::before').opacity,
    ),
  ).toBe('1');
});

function workspaceItem(path) {
  return workspaceSelector(path, { root: 'memory://workspace' });
}

async function inlineDeletedWindowEvidence(pane) {
  return pane.evaluate((root) => {
    const block = root.querySelector('.diff-editor-inline-deleted-block');
    const margin = root.querySelector('.diff-editor-inline-deleted-margin');
    const rows = Array.from(block?.querySelectorAll('.view-line') ?? []);
    const markers = Array.from(
      margin?.querySelectorAll('.diff-editor-inline-delete-sign') ?? [],
    );
    const lineNumbers = rows.map((row) =>
      Number(row.getAttribute('data-model-line')),
    );
    return {
      rowCount: rows.length,
      firstLine: lineNumbers.at(0) ?? 0,
      lastLine: lineNumbers.at(-1) ?? 0,
      validText: rows.every((row, index) =>
        row.textContent.includes(`original_${lineNumbers[index] - 1}`),
      ),
      validMarkers: markers.length === rows.length,
      hasForgedLineNumbers: Boolean(margin?.querySelector('.line-numbers')),
      hasTokens: rows.some((row) => row.querySelector('[class*="mtk"]')),
    };
  });
}

async function fragmentedInlineEvidence(pane) {
  return pane.evaluate((root) => {
    const blocks = Array.from(
      root.querySelectorAll('.diff-editor-inline-deleted-block'),
    );
    let rowCount = 0;
    const activeFragments = new Set();
    const activeOriginalLines = [];
    let validText = true;
    let validMarkers = true;
    let hasForgedLineNumbers = false;
    let hasTokens = false;
    let activeBlockCount = 0;
    for (const block of blocks) {
      const rows = Array.from(block.querySelectorAll('.view-line'));
      if (!rows.length) continue;
      activeBlockCount += 1;
      rowCount += rows.length;
      const zoneId = block.getAttribute('monaco-view-zone');
      const margin = root.querySelector(
        `.diff-editor-inline-deleted-margin[monaco-view-zone="${zoneId}"]`,
      );
      const markers = Array.from(
        margin?.querySelectorAll('.diff-editor-inline-delete-sign') ?? [],
      );
      validMarkers &&= markers.length === rows.length;
      hasForgedLineNumbers ||= Boolean(margin?.querySelector('.line-numbers'));
      for (const row of rows) {
        const originalLine = Number(row.getAttribute('data-model-line'));
        const match = row.textContent.match(/fragment_(\d+)_deleted_(\d+)/);
        if (!match) {
          validText = false;
          continue;
        }
        const fragment = Number(match[1]);
        const deletedLine = Number(match[2]);
        activeFragments.add(fragment);
        activeOriginalLines.push(originalLine);
        validText &&= originalLine === fragment * 131 + deletedLine + 1;
        hasTokens ||= Boolean(row.querySelector('[class*="mtk"]'));
      }
    }
    return {
      rowCount,
      activeBlockCount,
      activeFragments: Array.from(activeFragments),
      activeOriginalLines,
      validText,
      validMarkers,
      hasForgedLineNumbers,
      hasTokens,
    };
  });
}

async function setViewerStackWidth(stack, diff, width) {
  await stack.evaluate((element, nextWidth) => {
    element.style.width = `${nextWidth}px`;
    element.style.flex = `0 0 ${nextWidth}px`;
  }, width);
  await expect
    .poll(async () => Math.round((await diff.boundingBox())?.width ?? 0))
    .toBe(width);
}

async function diffScrollState(diff) {
  return diff.evaluate((root) => {
    const paneState = (paneClass) => {
      const pane = root.querySelector(paneClass);
      const scrollable = pane?.querySelector(
        '.monaco-scrollable-element.editor-scrollable',
      );
      const content = pane?.querySelector('.lines-content');
      const viewLines = pane?.querySelector('.view-lines');
      if (!scrollable || !content || !viewLines) {
        throw new Error(`missing diff scroll geometry for ${paneClass}`);
      }
      const style = getComputedStyle(content);
      const left = Math.max(0, -(Number.parseFloat(style.left) || 0));
      const top = Math.max(0, -(Number.parseFloat(style.top) || 0));
      const scrollWidth = viewLines.getBoundingClientRect().width;
      const viewportWidth = scrollable.getBoundingClientRect().width;
      return {
        left,
        top,
        scrollWidth,
        viewportWidth,
        maxLeft: Math.max(0, scrollWidth - viewportWidth),
      };
    };
    return {
      original: paneState('.moonbit-diff-editor-original'),
      modified: paneState('.moonbit-diff-editor-modified'),
    };
  });
}

async function scrollAxisDelta(diff, axis) {
  const state = await diffScrollState(diff);
  return Math.abs(state.original[axis] - state.modified[axis]);
}

async function settleAnimationFrames(page, count) {
  await page.evaluate(
    async (frameCount) => {
      for (let index = 0; index < frameCount; index += 1) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
      }
    },
    count,
  );
}

async function expectNoDiffPresentation(diff) {
  await expect(
    diff.locator([
      '.diff-editor-line-delete',
      '.diff-editor-line-insert',
      '.diff-editor-char-delete',
      '.diff-editor-char-insert',
      '.diff-editor-gutter-delete',
      '.diff-editor-gutter-insert',
      '.delete-sign',
      '.insert-sign',
      '.diff-editor-inline-deleted-block',
      '.diff-editor-inline-delete-sign',
    ].join(', ')),
  ).toHaveCount(0);
  await expect(diff.getByText('No modifications', { exact: true })).toHaveCount(0);
  const overviewRulers = diff.locator('.moonbit-code-overview-ruler');
  await expect(overviewRulers).toHaveCount(2);
  for (const ruler of await overviewRulers.all()) {
    await expect(ruler).toHaveAttribute('data-overview-ruler-entry-count', '0');
    await expect(ruler).toHaveAttribute('data-overview-ruler-band-count', '0');
  }
  const status = diff.locator('.moonbit-diff-editor-status');
  await expect(status).toHaveAttribute('hidden', '');
  await expect(status).toBeHidden();
}

async function viewportCodeAnchor(pane) {
  return pane.evaluate((root) => {
    const editor = root.querySelector('.monaco-editor');
    const editorRect = editor?.getBoundingClientRect();
    if (!editorRect) return null;
    const visible = Array.from(root.querySelectorAll('.view-lines .view-line'))
      .filter((line) => {
        const rect = line.getBoundingClientRect();
        return rect.bottom > editorRect.top && rect.top < editorRect.bottom;
      })
      .sort((left, right) =>
        left.getBoundingClientRect().top - right.getBoundingClientRect().top,
      );
    for (const line of visible) {
      const text = line.textContent.replaceAll('\u00a0', ' ').trim();
      const match = text.match(/(?:stable|replacement|changed|inserted_after_comment)_(\d+)/);
      if (!match) continue;
      return {
        text,
        modelIndex: Number(match[1]),
        offset: line.getBoundingClientRect().top - editorRect.top,
      };
    }
    return null;
  });
}

async function matchingCodeLineTopDelta(diff, text) {
  return diff.evaluate((root, expectedText) => {
    const find = (paneClass) =>
      Array.from(
        root.querySelectorAll(`${paneClass} .view-lines .view-line`),
      ).find(
        (line) =>
          line.textContent.replaceAll('\u00a0', ' ').trim() === expectedText,
      );
    const original = find('.moonbit-diff-editor-original');
    const modified = find('.moonbit-diff-editor-modified');
    if (!original || !modified) return Number.POSITIVE_INFINITY;
    return Math.abs(
      original.getBoundingClientRect().top - modified.getBoundingClientRect().top,
    );
  }, text);
}
