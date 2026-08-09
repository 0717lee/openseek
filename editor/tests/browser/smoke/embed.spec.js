import { expect, test } from '../support/test.js';
import { workspaceItem as workspaceSelector } from '../support/app.js';

// Proves the library boundary: the embedded page runs the viewer and the
// file-tree widget against in-memory providers, with no websocket opened.
test('runs the viewer and tree from in-memory providers without a server', async ({ page }) => {
  const websockets = [];
  page.on('websocket', (ws) => websockets.push(ws.url()));

  await page.goto('/embed.html');

  // The embedding host auto-opens src/main.mbt; auto-reveal expands src.
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator('.monaco-editor.readonly-editor')).toContainText('fn main');
  await expect
    .poll(async () => (await page.locator('.embedded-viewer-stack').boundingBox())?.width ?? 0)
    .toBeGreaterThan(400);

  // Real language highlighting with no server: the MoonBit lexer is
  // registered by the embedding host, not fetched from anywhere.
  await expect(page.locator('.mtk3', { hasText: 'fn' }).first()).toBeVisible();
  await expect(page.locator(workspaceItem('src'))).toHaveAttribute('aria-expanded', 'true');
  await expect(page.locator(workspaceItem('src/main.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );

  // The same public facade exposes a standalone unified-diff surface. The
  // host toggles sibling surfaces, preserving the ordinary Viewer's model and
  // scroll while the renderer receives only original/modified source text.
  const diffToggle = page.locator('[data-action=\"toggle-diff\"]');
  await diffToggle.click();
  await expect(diffToggle).toHaveAttribute('aria-pressed', 'true');
  const diff = page.locator('.moonbit-unified-diff');
  await expect(diff).toBeVisible();
  await expect
    .poll(async () => (await diff.boundingBox())?.width ?? 0)
    .toBeGreaterThan(400);
  await diff.focus();
  await expect(diff).toBeFocused();
  await expect
    .poll(() => diff.evaluate((element) => getComputedStyle(element).outlineStyle))
    .toBe('solid');
  const deletion = diff.locator('[data-line-kind=\"deletion\"]', {
    hasText: 'println(\"hello\")',
  });
  await expect(deletion).toHaveAttribute('data-original-line', '3');
  await expect(deletion).toHaveAttribute(
    'aria-label',
    'Deletion, original line 3:   println(\"hello\")',
  );
  const addition = diff.locator('[data-line-kind=\"addition\"]', {
    hasText: 'println(greeting())',
  });
  await expect(addition).toHaveAttribute('data-modified-line', '3');
  await expect(addition).toHaveAttribute(
    'aria-label',
    'Addition, modified line 3:   println(greeting())',
  );
  await expect(page.locator('.monaco-editor.readonly-editor')).not.toBeVisible();

  await diffToggle.click();
  await expect(diffToggle).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('.moonbit-unified-diff')).toHaveCount(0);
  await expect(page.locator('.monaco-editor.readonly-editor')).toContainText('fn main');

  // Nested folders resolve lazily on expand.
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toHaveCount(0);
  await page.locator(workspaceItem('src/lib')).click();
  await expect(page.locator(workspaceItem('src/lib'))).toHaveAttribute('aria-expanded', 'true');

  // Navigating between files goes through the in-memory document source.
  await page.locator(workspaceItem('src/lib/util.mbt')).click();
  await expect(page.locator('.monaco-editor.readonly-editor')).toContainText('util_answer');
  await expect(page.locator(workspaceItem('src/lib/util.mbt'))).toHaveAttribute(
    'aria-selected',
    'true',
  );

  // The same public Viewer instance selects its Markdown presentation from an
  // ordinary URI-backed in-memory model. No workbench or host-side Markdown
  // parsing/presentation branch participates.
  await page.locator(workspaceItem('README.md')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await expect(page.locator(workspaceItem('README.md'))).toHaveAttribute(
    'aria-selected',
    'true',
  );
  const markdown = page.locator(
    '.viewer-host > .moonbit-viewer-markdown-document',
  );
  await expect(markdown).toBeVisible();
  await expect(markdown).toHaveAttribute(
    'data-source-uri',
    'memory://workspace/README.md',
  );
  await expect(markdown.locator('h1')).toHaveText('Embedded Markdown document');
  await expect(markdown.locator('strong')).toHaveText('Viewer');
  await expect(page.locator('.viewer-host > .monaco-editor')).toHaveCount(0);

  expect(websockets).toEqual([]);
});

test('bounds eager DOM rendering for a legal-size large diff', async ({ page }) => {
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');

  // Both sides are well below the desktop's 1 MiB source limit, but their
  // many short changed lines would otherwise create tens of thousands of DOM
  // elements synchronously.
  await page.locator(workspaceItem('large.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();
  await expect(page.locator('.moonbit-unified-diff')).toContainText(
    'This diff is too large to render safely.',
  );
  await expect(page.locator('.moonbit-unified-diff-line')).toHaveCount(0);
});

test('rejects an oversized single-line comparison before diffing', async ({ page }) => {
  await page.goto('/embed.html');
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');

  await page.locator(workspaceItem('oversized-line.mbt')).click();
  await expect(page.locator('.editor-shell')).toHaveAttribute('data-status', 'ready');
  await page.locator('[data-action="toggle-diff"]').click();
  await expect(page.locator('.moonbit-unified-diff')).toContainText(
    'This diff is too large to render safely.',
  );
  await expect(page.locator('.moonbit-unified-diff-line')).toHaveCount(0);
});

test('drops a stale host-ready rAF after a rapid model swap', async ({ page }) => {
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

  // Hold the host-ready callbacks while the Viewer itself continues to render
  // on the browser's native rAF queue. The first callback captures moon.mod;
  // the second captures util.mbt, which is the current model by flush time.
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
  await expect(page.locator('.monaco-editor.readonly-editor')).toContainText(
    'util_answer',
  );
});

function workspaceItem(path) {
  return workspaceSelector(path, { root: 'memory://workspace' });
}
