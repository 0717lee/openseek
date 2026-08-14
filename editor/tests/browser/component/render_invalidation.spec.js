import { expect, test } from '../support/test.js';

const editorSelector =
  '.render-invalidation-host > .monaco-editor.readonly-editor';
const visibleHoverSelector =
  '.render-invalidation-host [data-content-widget="editor.contrib.resizableContentHoverWidget"] .monaco-hover:not(.hidden)';
const contentWidgetSelector =
  '.render-invalidation-host [data-content-widget="editor.contrib.resizableContentHoverWidget"]';

async function settle(page) {
  await page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
}

async function mountFixture(page) {
  await page.goto('/browser-tests/component.html?renderInvalidation=1');
  await page.waitForFunction(() => Boolean(globalThis.__renderInvalidationControls));
  await expect(page.locator(editorSelector)).toContainText('prefix anchor target');
  await expect(
    page.locator('.render-invalidation-host .cdr.squiggly-warning'),
  ).toHaveCount(1);
  await settle(page);
}

async function update(page, method, value) {
  await page.evaluate(
    ([name, nextValue]) =>
      globalThis.__renderInvalidationControls[name](nextValue),
    [method, value],
  );
  await settle(page);
}

async function probeUpdate(page, callback) {
  await page.evaluate(() => globalThis.__renderInvalidationControls.start_probe());
  await callback();
  // Do not use requestAnimationFrame to observe this interval: the fixture
  // counts every scheduled frame, including frames requested by test code.
  await page.waitForTimeout(120);
  return page.evaluate(() =>
    globalThis.__renderInvalidationControls.stop_probe(),
  );
}

async function pointForText(page, needle) {
  const point = await page
    .locator('.render-invalidation-host .view-lines')
    .evaluate((root, text) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const index = node.textContent.indexOf(text);
        if (index < 0) continue;
        const range = document.createRange();
        range.setStart(node, index);
        range.setEnd(node, index + text.length);
        const rect = range.getBoundingClientRect();
        return {
          x: rect.x + rect.width / 2,
          y: rect.y + rect.height / 2,
        };
      }
      return null;
    }, needle);
  expect(point).not.toBeNull();
  return point;
}

test('runtime whitespace and control-character options replace rendered DOM immediately', async ({
  page,
}) => {
  await mountFixture(page);
  const whitespace = page.locator('.render-invalidation-host .view-line .mtkw');
  const control = page.locator(
    '.render-invalidation-host .view-line .mtkcontrol',
  );

  await expect(whitespace).toHaveCount(0);
  await expect(control).toHaveCount(0);

  await update(page, 'set_whitespace', 'all');
  await expect(whitespace.first()).toBeVisible();
  await update(page, 'set_whitespace', 'none');
  await expect(whitespace).toHaveCount(0);

  await update(page, 'set_control', true);
  await expect(control).toHaveCount(1);
  await expect(control).toHaveText('[U+202E]');
  await update(page, 'set_control', false);
  await expect(control).toHaveCount(0);
  await expect(page.locator(editorSelector)).not.toContainText('[U+202E]');
});

test('spacing and token invalidations reproject only their DOM consumers', async ({
  page,
}) => {
  await mountFixture(page);
  await page.evaluate(() => globalThis.__renderInvalidationControls.focus());
  await settle(page);
  const cursor = page.locator('.render-invalidation-host .cursor').first();
  await expect(cursor).toBeVisible();

  const anchor = await pointForText(page, 'anchor');
  await page.mouse.move(anchor.x, anchor.y);
  await expect(page.locator(visibleHoverSelector)).toContainText(
    'render invalidation hover',
  );
  await settle(page);
  const widget = page.locator(contentWidgetSelector);
  await expect(widget).toBeVisible();

  const initialCursorBox = await cursor.boundingBox();
  const initialWidgetBox = await widget.boundingBox();
  const initialPosition = await page.evaluate(() =>
    globalThis.__renderInvalidationControls.position(),
  );
  expect(initialCursorBox).not.toBeNull();
  expect(initialWidgetBox).not.toBeNull();
  expect(initialPosition).toEqual({ line: 1, column: 21 });

  const added = await probeUpdate(page, () =>
    page.evaluate(() =>
      globalThis.__renderInvalidationControls.add_spacing_decoration(),
    ),
  );
  expect(added.frames).toBe(1);
  expect(added.targets).toContain('viewLine');
  expect(added.writes).toContain('cursor');
  expect(added.writes).toContain('contentWidget');
  await expect(
    page.locator('.render-invalidation-host .render-invalidation-spacing'),
  ).toHaveCount(1);
  const decoratedCursorBox = await cursor.boundingBox();
  expect(decoratedCursorBox).not.toBeNull();
  // Cursor geometry already uses a live DOM Range. The spacing decoration is
  // before the unchanged model position, so a recomputation visibly moves it.
  expect(decoratedCursorBox.x).toBeGreaterThan(initialCursorBox.x + 20);
  expect(
    await page.evaluate(() => globalThis.__renderInvalidationControls.position()),
  ).toEqual(initialPosition);
  await expect(widget).toBeVisible();

  const removed = await probeUpdate(page, () =>
    page.evaluate(() =>
      globalThis.__renderInvalidationControls.remove_spacing_decoration(),
    ),
  );
  expect(removed.frames).toBe(1);
  expect(removed.targets).toContain('viewLine');
  expect(removed.writes).toContain('cursor');
  expect(removed.writes).toContain('contentWidget');
  await expect(
    page.locator('.render-invalidation-host .render-invalidation-spacing'),
  ).toHaveCount(0);
  const restoredCursorBox = await cursor.boundingBox();
  expect(restoredCursorBox).not.toBeNull();
  expect(Math.abs(restoredCursorBox.x - initialCursorBox.x)).toBeLessThanOrEqual(
    1,
  );
  expect(
    await page.evaluate(() => globalThis.__renderInvalidationControls.position()),
  ).toEqual(initialPosition);
  await expect(widget).toBeVisible();

  const tokenChanged = await probeUpdate(page, () =>
    page.evaluate(() =>
      globalThis.__renderInvalidationControls.recolor_tokens(),
    ),
  );
  expect(tokenChanged.frames).toBe(1);
  expect(tokenChanged.targets).toContain('viewLine');
  expect(tokenChanged.writes).toContain('cursor');
  expect(tokenChanged.writes).not.toContain('contentWidget');
  await expect(
    page.locator('.render-invalidation-host .view-line .mtk3').first(),
  ).toBeVisible();
  await expect(widget).toBeVisible();
});

test('same-geometry layout_zone retains node and rereads callback in one frame', async ({
  page,
}) => {
  await mountFixture(page);
  await update(page, 'replace_zone');
  await expect(
    page.locator(
      '.render-invalidation-host [data-zone-generation="1"]',
    ),
  ).toHaveCount(1);
  const retainedNode = await page
    .locator('.render-invalidation-host [data-zone-generation="1"]')
    .elementHandle();
  expect(retainedNode).not.toBeNull();
  const before = await page.evaluate(() =>
    globalThis.__renderInvalidationControls.zone_counts(),
  );
  expect(before.first).toBeGreaterThan(0);

  const changed = await probeUpdate(page, () =>
    page.evaluate(() => globalThis.__renderInvalidationControls.replace_zone()),
  );
  const after = await page.evaluate(() =>
    globalThis.__renderInvalidationControls.zone_counts(),
  );
  expect(changed.frames).toBe(1);
  await expect(
    page.locator(
      '.render-invalidation-host [data-zone-generation="1"]',
    ),
  ).toHaveCount(1);
  await expect(
    page.locator(
      '.render-invalidation-host [data-zone-generation="2"]',
    ),
  ).toHaveCount(0);
  expect(
    await retainedNode.evaluate(
      (node) =>
        node ===
        document.querySelector(
          '.render-invalidation-host [data-zone-generation="1"]',
        ),
    ),
  ).toBe(true);
  expect(after.first).toBe(before.first);
  expect(after.second).toBeGreaterThan(0);
});
