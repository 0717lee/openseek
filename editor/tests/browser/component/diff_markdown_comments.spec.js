import { expect, test } from '../support/test.js';

const rootSelector =
  '.diff-markdown-comments-host > .moonbit-diff-editor';
const commentSelector = '.moonbit-viewer-markdown-comment';

async function openFixture(page) {
  await page.goto('/browser-tests/component.html?diffMarkdownComments=1');
  await page.waitForFunction(() =>
    Boolean(globalThis.__diffMarkdownCommentsControls),
  );
  const root = page.locator(rootSelector);
  await expect(root).toHaveCount(1);
  return root;
}

async function control(page, method, value) {
  await page.evaluate(({ method: name, value: argument }) => {
    globalThis.__diffMarkdownCommentsControls[name](argument);
  }, { method, value });
}

async function waitForFrames(page, count = 4) {
  await page.evaluate((frameCount) => new Promise((resolve) => {
    let remaining = frameCount;
    const advance = () => {
      remaining -= 1;
      if (remaining <= 0) resolve();
      else requestAnimationFrame(advance);
    };
    requestAnimationFrame(advance);
  }), count);
}

async function expectTailAlignment(root) {
  await expect.poll(() => root.evaluate((node) => {
    const tailTop = (paneClass) => {
      const pane = node.querySelector(paneClass);
      const lines = Array.from(pane.querySelectorAll(
        '.view-lines[data-view-part="view-lines"] > .view-line',
      ));
      const line = lines.at(-1);
      return line?.getBoundingClientRect().top ?? null;
    };
    const original = tailTop('.moonbit-diff-editor-original');
    const modified = tailTop('.moonbit-diff-editor-modified');
    if (original == null || modified == null) return null;
    return Math.abs(original - modified);
  })).not.toBeNull();
  await expect.poll(() => root.evaluate((node) => {
    const top = (paneClass) => Array.from(
      node.querySelector(paneClass).querySelectorAll(
        '.view-lines[data-view-part="view-lines"] > .view-line',
      ),
    ).at(-1)?.getBoundingClientRect().top;
    const original = top('.moonbit-diff-editor-original');
    const modified = top('.moonbit-diff-editor-modified');
    return original == null || modified == null
      ? Number.POSITIVE_INFINITY
      : Math.abs(original - modified);
  })).toBeLessThanOrEqual(1);
}

async function expectOriginalLineNumbers(original, expected) {
  await expect.poll(() => original.evaluate((node) =>
    Array.from(node.querySelectorAll('.line-numbers'), (line) =>
      line.textContent.trim(),
    ),
  )).toEqual(expect.arrayContaining(expected));
}

async function contentHeightState(page) {
  return page.evaluate(() => {
    const controls = globalThis.__diffMarkdownCommentsControls;
    const host = document.querySelector('.diff-markdown-comments-host');
    return {
      eventCount: controls.content_height_event_count(),
      contentHeight: controls.content_height(),
      hostHeight: host.getBoundingClientRect().height,
    };
  });
}

test('keeps rich comments in both split panes and only the modified inline pane', async ({ page }) => {
  const root = await openFixture(page);
  const original = root.locator('.moonbit-diff-editor-original');
  const modified = root.locator('.moonbit-diff-editor-modified');

  expect(await page.evaluate(() =>
    globalThis.__diffMarkdownCommentsControls.initialHiddenOriginalComments,
  )).toBe(0);
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectOriginalLineNumbers(original, ['2', '3', '4', '5', '6']);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'split');
  await expect(root).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectTailAlignment(root);

  await control(page, 'resize', 620);
  await waitForFrames(page);
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'inline');
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectOriginalLineNumbers(original, ['2', '3', '4', '5', '6']);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'split');
  await expect(root).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectTailAlignment(root);
});

test('aligns replacement comments through resize and layout round trips', async ({ page }) => {
  const root = await openFixture(page);
  const original = root.locator('.moonbit-diff-editor-original');
  const modified = root.locator('.moonbit-diff-editor-modified');

  await control(page, 'set_fixture', 'replacement');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expect(
    modified.locator('.diff-editor-inline-deleted-block'),
  ).toHaveCount(1);
  await expectOriginalLineNumbers(original, ['2', '3', '4', '5']);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'split');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectTailAlignment(root);

  await control(page, 'resize', 540);
  await waitForFrames(page);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'inline');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expect(
    modified.locator('.diff-editor-inline-deleted-block'),
  ).toHaveCount(1);
  await expectOriginalLineNumbers(original, ['2', '3', '4', '5']);
  await expectTailAlignment(root);

  await control(page, 'resize', 760);
  await waitForFrames(page);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'split');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expectTailAlignment(root);
});

test('balances a final-line change inside a compact multi-line comment', async ({ page }) => {
  const root = await openFixture(page);
  const original = root.locator('.moonbit-diff-editor-original');
  const modified = root.locator('.moonbit-diff-editor-modified');
  const modifiedCompensation = modified.locator(
    '.moonbit-diff-editor-inline-modified-companion-spacer',
  );

  await control(page, 'set_fixture', 'partial');
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expect(
    modified.locator('.diff-editor-inline-deleted-block'),
  ).toHaveCount(1);
  await expect(modifiedCompensation).toHaveCount(1);
  await expect.poll(() => modifiedCompensation.evaluate((node) =>
    node.getBoundingClientRect().height,
  )).toBeGreaterThan(0);
  await expectOriginalLineNumbers(
    original,
    ['2', '3', '4', '5', '6', '7', '8'],
  );
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'split');
  await expect(root).toHaveAttribute('data-render-mode', 'side-by-side');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expect(modifiedCompensation).toHaveCount(0);
  await expectTailAlignment(root);

  await control(page, 'set_layout', 'inline');
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await expect(original.locator(commentSelector)).toHaveCount(0);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await expect(modifiedCompensation).toHaveCount(1);
  await expectTailAlignment(root);
});

test('publishes one final paired height for a Markdown comment fold change', async ({ page }) => {
  const root = await openFixture(page);
  const original = root.locator('.moonbit-diff-editor-original');
  const modified = root.locator('.moonbit-diff-editor-modified');

  await control(page, 'set_layout', 'split');
  await expect(original.locator(commentSelector)).toHaveCount(1);
  await expect(modified.locator(commentSelector)).toHaveCount(1);
  await waitForFrames(page, 6);
  await page.evaluate(() => {
    globalThis.__diffMarkdownCommentsControls.enable_auto_height();
  });
  await waitForFrames(page, 4);

  const folded = await contentHeightState(page);
  expect(Math.abs(
    folded.hostHeight - Math.max(40, Math.ceil(folded.contentHeight) + 2),
  )).toBeLessThanOrEqual(1);

  await modified.locator(
    '.moonbit-viewer-markdown-comment-toggle[aria-label="Expand API documentation"]',
  ).click();
  await expect.poll(async () =>
    (await contentHeightState(page)).eventCount,
  ).toBe(folded.eventCount + 1);

  const expanded = await contentHeightState(page);
  expect(expanded.hostHeight).toBeGreaterThan(folded.hostHeight);
  expect(Math.abs(
    expanded.hostHeight - Math.max(40, Math.ceil(expanded.contentHeight) + 2),
  )).toBeLessThanOrEqual(1);
  await expect.poll(() => modified.locator(commentSelector).evaluate((node) => {
    const content = node.querySelector(
      '.moonbit-viewer-markdown-comment-content',
    );
    return Math.abs(
      node.getBoundingClientRect().height - content.offsetHeight,
    );
  })).toBeLessThanOrEqual(1);
  await expectTailAlignment(root);

  await waitForFrames(page, 6);
  const stableExpanded = await contentHeightState(page);
  expect(stableExpanded.eventCount).toBe(expanded.eventCount);
  expect(Math.abs(stableExpanded.hostHeight - expanded.hostHeight))
    .toBeLessThanOrEqual(1);

  await modified.locator(
    '.moonbit-viewer-markdown-comment-toggle[aria-label="Collapse API documentation"]',
  ).click();
  await expect.poll(async () =>
    (await contentHeightState(page)).eventCount,
  ).toBe(expanded.eventCount + 1);
  const collapsed = await contentHeightState(page);
  expect(collapsed.hostHeight).toBeLessThan(expanded.hostHeight);
  expect(Math.abs(
    collapsed.hostHeight - Math.max(40, Math.ceil(collapsed.contentHeight) + 2),
  )).toBeLessThanOrEqual(1);
  expect(Math.abs(collapsed.hostHeight - folded.hostHeight))
    .toBeLessThanOrEqual(1);
  await expectTailAlignment(root);

  await waitForFrames(page, 6);
  const stableCollapsed = await contentHeightState(page);
  expect(stableCollapsed.eventCount).toBe(collapsed.eventCount);
  expect(Math.abs(stableCollapsed.hostHeight - collapsed.hostHeight))
    .toBeLessThanOrEqual(1);
});
