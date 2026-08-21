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

  // Algorithm controls are a host/provider concern. DiffEditor itself contains
  // neither the removed toolbar nor the host-owned layout action.
  await expect(diff.locator('.moonbit-diff-editor-toolbar')).toHaveCount(0);
  await expect(diff.locator('[data-action="toggle-diff-layout"]')).toHaveCount(0);

  await expect(layoutToggle).toBeEnabled();
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'false');
  await layoutToggle.click();
  await expect(layoutToggle).toHaveAttribute('aria-pressed', 'true');
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(originalPane).toBeHidden();
  await expect(originalPane).toHaveAttribute('aria-hidden', 'true');
  await expect(modifiedPane).toHaveAccessibleName('Inline diff');
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

test('switches at the 900/901 boundary and keeps explicit Inline above it', async ({ page }) => {
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
  await expect(originalPane).toBeHidden();
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
  await expect(originalPane).toBeHidden();
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

test('moves original focus into Inline and keeps F7 navigation live', async ({ page }) => {
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

  // Responsive layout changes do not move focus through a toolbar button.
  await setViewerStackWidth(stack, diff, 900);
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect
    .poll(() =>
      modifiedPane.evaluate((node) => node.contains(document.activeElement)),
    )
    .toBe(true);
  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(
    'Change 1 of 2; original lines 3 through 3; modified deletion anchor at line 3',
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
  const spacers = diff.locator('.moonbit-diff-editor-alignment-spacer[monaco-view-zone]');
  await expect.poll(() => spacers.count()).toBeGreaterThan(0);
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
  expect(await firstChangedLineTopDelta(diff)).toBeLessThanOrEqual(1);

  await page.locator('[data-action="toggle-diff-layout"]').click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
  await page.locator('[data-action="toggle-diff-layout"]').click();
  await expect(diff).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect.poll(() => spacers.count()).toBeGreaterThan(0);
  expect(await firstChangedLineTopDelta(diff)).toBeLessThanOrEqual(1);
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
    'Change 2 of 2; original insertion anchor at line 6; modified lines 5 through 5';
  await expect(liveRegion).toHaveAttribute('aria-live', 'polite');
  await expect(liveRegion).toHaveAttribute('aria-atomic', 'true');
  await expect(originalPane.locator('.diff-editor-line-delete')).toHaveCount(1);
  await expect(modifiedPane.locator('.diff-editor-line-insert')).toHaveCount(1);

  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });

  // Side-by-side navigates to the pane that owns physical changed lines.
  await page.keyboard.press('F7');
  await expect(liveRegion).toHaveText(deletionAnnouncement);
  await expect
    .poll(() =>
      page.evaluate(() =>
        document
          .querySelector('.moonbit-diff-editor-original')
          ?.contains(document.activeElement),
      ),
    )
    .toBe(true);

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

  // Inline has one interactive surface. Consecutive F7 presses reveal both
  // kinds of hunk in the modified editor, including the deletion-only anchor.
  await layoutToggle.click();
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
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

  await page.keyboard.press('Shift+F7');
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
});

test('virtualizes a 2600-line Inline deletion through the viewport', async ({ page }) => {
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
  const block = modifiedPane.locator(
    '.diff-editor-inline-deleted-block[data-virtualized-render-lines="true"]',
  );
  await expect(block).toHaveCount(1);
  await expect(block).toHaveAttribute('data-original-line-start', '1');
  await expect(block).toHaveAttribute('data-original-line-end-exclusive', '2601');

  // Installing a leading Inline zone preserves the raw viewport origin. It
  // must not restore modified line 1 below the new 46,800px deletion.
  await expect
    .poll(() => block.getAttribute('data-render-window-start-model-line'))
    .toBe('1');

  const top = await inlineDeletedWindowEvidence(modifiedPane);
  expect(top.rowCount).toBeLessThan(200);
  expect(top.firstLine).toBe(1);
  expect(top.validText).toBeTruthy();
  expect(top.validLineNumbers).toBeTruthy();
  expect(top.hasTokens).toBeTruthy();

  // The editor's Monaco-shaped wheel path multiplies pixel deltas by 1.25.
  // 18,720px therefore lands at 23,400px, the middle of the 46,800px zone.
  await wheelInlinePane(modifiedPane, 18_720);
  await expect
    .poll(() => block.getAttribute('data-render-window-start-model-line'))
    .not.toBe('1');
  const middle = await inlineDeletedWindowEvidence(modifiedPane);
  expect(middle.rowCount).toBeLessThan(200);
  expect(middle.firstLine).toBeGreaterThan(1_000);
  expect(middle.lastLine).toBeLessThan(1_800);
  expect(middle.validText).toBeTruthy();
  expect(middle.validLineNumbers).toBeTruthy();
  expect(middle.hasTokens).toBeTruthy();

  // A geometry-only Inline reconcile replaces the rendering context but
  // preserves the current model-line anchor once the projection already
  // exists. Resizing in the middle must not fall back to the raw/topology
  // installation behavior.
  await page.setViewportSize({ width: 1360, height: 900 });
  await expect
    .poll(async () => (await inlineDeletedWindowEvidence(modifiedPane)).firstLine)
    .toBe(middle.firstLine);
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);

  // Another movement keeps the zone intersecting the viewport while
  // exposing its final original row rather than overshooting into insertions.
  await wheelInlinePane(modifiedPane, 18_500);
  await expect
    .poll(() => block.getAttribute('data-render-window-end-model-line'))
    .toBe('2600');
  const tail = await inlineDeletedWindowEvidence(modifiedPane);
  expect(tail.rowCount).toBeLessThan(200);
  expect(tail.lastLine).toBe(2600);
  expect(tail.validText).toBeTruthy();
  expect(tail.validLineNumbers).toBeTruthy();
  expect(tail.hasTokens).toBeTruthy();
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);
});

test('shares the Inline DOM budget across twenty 130-line deletions', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator(workspaceItem('fragmented-large.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();
  await page.locator('[data-action="toggle-diff-layout"]').click();

  const diff = page.locator(diffEditor);
  const modifiedPane = diff.locator('.moonbit-diff-editor-modified');
  const blocks = modifiedPane.locator(
    '.diff-editor-inline-deleted-block[data-virtualized-render-lines="true"]',
  );
  await expect(diff).toHaveAttribute('data-render-mode', 'inline');
  await expect(blocks).toHaveCount(20);

  // F7 on a deletion-only Inline hunk reveals the ViewZone top itself, not
  // the retained modified line after its 130 deleted rows. This also gives
  // the fragmented budget test a deterministic content-space origin even if
  // SideBySide alignment had retained a non-zero raw scroll offset.
  await modifiedPane.locator('.monaco-editor').click({ position: { x: 120, y: 80 } });
  await page.keyboard.press('F7');
  await expect
    .poll(async () => (await fragmentedInlineEvidence(modifiedPane)).activeFragments)
    .toContain(0);
  const top = await fragmentedInlineEvidence(modifiedPane);
  expect(top.rowCount).toBeLessThan(100);
  expect(top.activeBlockCount).toBeLessThanOrEqual(2);
  expect(top.validText).toBeTruthy();
  expect(top.validLineNumbers).toBeTruthy();
  expect(top.hasTokens).toBeTruthy();
  expect(top.activeOriginalLines).toContain(1);
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);

  await wheelInlinePane(modifiedPane, 18_720);
  await expect
    .poll(async () => (await fragmentedInlineEvidence(modifiedPane)).activeFragments)
    .toContain(10);
  const middle = await fragmentedInlineEvidence(modifiedPane);
  expect(middle.rowCount).toBeLessThan(100);
  expect(middle.activeBlockCount).toBeLessThanOrEqual(2);
  expect(middle.validText).toBeTruthy();
  expect(middle.validLineNumbers).toBeTruthy();
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);

  await wheelInlinePane(modifiedPane, 18_700);
  await expect
    .poll(async () => (await fragmentedInlineEvidence(modifiedPane)).activeFragments)
    .toContain(19);
  const tail = await fragmentedInlineEvidence(modifiedPane);
  expect(tail.rowCount).toBeLessThan(100);
  expect(tail.activeBlockCount).toBeLessThanOrEqual(2);
  // The twentieth 130-line deletion spans original lines 2490..2619;
  // original line 2620 is its retained anchor and belongs to the code model.
  expect(tail.activeOriginalLines).toContain(2619);
  expect(tail.validText).toBeTruthy();
  expect(tail.validLineNumbers).toBeTruthy();
  expect(await diff.locator('.view-line').count()).toBeLessThan(200);
});

test('renders character changes in the side-by-side code kernels', async ({ page }) => {
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
  await expect(originalPane.locator('.diff-editor-char-delete')).toHaveText('1');
  await expect(modifiedPane.locator('.diff-editor-char-insert')).toHaveText('2');
  await expect(originalPane.locator('.diff-editor-line-delete')).toHaveCount(1);
  await expect(modifiedPane.locator('.diff-editor-line-insert')).toHaveCount(1);
});

test('drops a stale host-ready rAF after a rapid code-model swap', async ({ page }) => {
  await page.addInitScript(() => {
    const queue = [];
    globalThis.__embeddedReadyAnimationFrame = (callback) => {
      queue.push(callback);
    };
    globalThis.__embeddedReadyQueueLength = () => queue.length;
    globalThis.__flushEmbeddedReadyFrame = () => {
      const callback = queue.shift();
      if (callback) callback();
    };
  });

  await page.goto('/embed.html');
  await expect
    .poll(() => page.evaluate(() => globalThis.__embeddedReadyQueueLength()))
    .toBe(1);
  await page.evaluate(() => globalThis.__flushEmbeddedReadyFrame());
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator(workspaceItem('src/main.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );

  await page.locator(workspaceItem('src/lib')).click();
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toBeVisible();
  await page.locator(workspaceItem('moon.mod')).click();
  await expect
    .poll(() => page.evaluate(() => globalThis.__embeddedReadyQueueLength()))
    .toBe(1);
  await page.locator(workspaceItem('src/lib/util.mbt')).click();
  await expect
    .poll(() => page.evaluate(() => globalThis.__embeddedReadyQueueLength()))
    .toBe(2);
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'loading');

  await page.evaluate(() => globalThis.__flushEmbeddedReadyFrame());
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'loading');
  await page.evaluate(() => globalThis.__flushEmbeddedReadyFrame());
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );
  await expect(page.locator(sourceEditor)).toContainText('util_answer');
});

function workspaceItem(path) {
  return workspaceSelector(path, { root: 'memory://workspace' });
}

async function wheelInlinePane(pane, deltaY) {
  await pane.locator('.overflow-guard').evaluate((node, wheelDelta) => {
    node.dispatchEvent(
      new WheelEvent('wheel', {
        deltaY: wheelDelta,
        deltaMode: 0,
        bubbles: true,
        cancelable: true,
      }),
    );
  }, deltaY);
}

async function inlineDeletedWindowEvidence(pane) {
  return pane.evaluate((root) => {
    const block = root.querySelector('.diff-editor-inline-deleted-block');
    const margin = root.querySelector('.diff-editor-inline-deleted-margin');
    const rows = Array.from(block?.querySelectorAll('.view-line') ?? []);
    const margins = new Map(
      Array.from(margin?.querySelectorAll('.line-numbers') ?? []).map((row) => [
        Number(row.getAttribute('data-model-line')),
        row.textContent.trim(),
      ]),
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
      validLineNumbers: lineNumbers.every(
        (lineNumber) => margins.get(lineNumber) === String(lineNumber),
      ),
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
    let validLineNumbers = true;
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
      const margins = new Map(
        Array.from(margin?.querySelectorAll('.line-numbers') ?? []).map((row) => [
          Number(row.getAttribute('data-model-line')),
          row.textContent.trim(),
        ]),
      );
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
        validLineNumbers &&= margins.get(originalLine) === String(originalLine);
        hasTokens ||= Boolean(row.querySelector('[class*="mtk"]'));
      }
    }
    return {
      rowCount,
      activeBlockCount,
      activeFragments: Array.from(activeFragments),
      activeOriginalLines,
      validText,
      validLineNumbers,
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

async function firstChangedLineTopDelta(diff) {
  return diff.evaluate((root) => {
    const original = root.querySelector(
      '.moonbit-diff-editor-original .diff-editor-line-delete',
    );
    const modified = root.querySelector(
      '.moonbit-diff-editor-modified .diff-editor-line-insert',
    );
    if (!original || !modified) return Number.POSITIVE_INFINITY;
    return Math.abs(
      original.getBoundingClientRect().top - modified.getBoundingClientRect().top,
    );
  });
}
