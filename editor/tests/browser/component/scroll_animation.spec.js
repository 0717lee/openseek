import { expect, gotoBrowserScenario, test } from '../support/test.js';

async function openSmoothViewer(page) {
  await gotoBrowserScenario(page, 'viewer-api');
  await expect(page.locator('.monaco-editor.readonly-editor')).toContainText(
    'component_answer',
    { timeout: 10_000 },
  );
}

async function scrollFacts(page) {
  return page.locator('.viewer-host').evaluate((host) => ({
    events: Number(host.dataset.scrollEvents || 0),
    top: Number(host.dataset.scrollTop || 0),
  }));
}

async function stableVerticalThumb(page) {
  const thumb = page.locator(
    '.monaco-scrollable-element.editor-scrollable > .scrollbar.vertical > .slider',
  );
  let previousSignature = '';
  let stableGeometry;
  await expect
    .poll(async () => {
      const geometry = await thumb.evaluate((node) => {
        const track = node.parentElement;
        if (!track) throw new Error('vertical scrollbar thumb has no track');
        const trackRect = track.getBoundingClientRect();
        const thumbRect = node.getBoundingClientRect();
        return {
          trackTop: trackRect.top,
          trackHeight: trackRect.height,
          thumbLeft: thumbRect.left,
          thumbTop: thumbRect.top,
          thumbWidth: thumbRect.width,
          thumbHeight: thumbRect.height,
        };
      });
      const signature = JSON.stringify(geometry);
      const hasDragRoom = geometry.trackHeight - geometry.thumbHeight >= 8;
      const unchanged = signature === previousSignature;
      previousSignature = signature;
      if (hasDragRoom && unchanged) stableGeometry = geometry;
      return hasDragRoom && unchanged;
    })
    .toBeTruthy();
  return { thumb, geometry: stableGeometry };
}

test('animates a classified physical wheel through multiple rAF states', async ({ page }) => {
  await openSmoothViewer(page);
  const before = await scrollFacts(page);
  const prevented = await page.evaluate(() => {
    const event = new WheelEvent('wheel', {
      deltaY: 40,
      deltaMode: 0,
      bubbles: true,
      cancelable: true,
    });
    document.querySelector('.overflow-guard').dispatchEvent(event);
    return event.defaultPrevented;
  });
  expect(prevented).toBeTruthy();
  await expect.poll(async () => (await scrollFacts(page)).top).toBe(before.top + 50);
  const after = await scrollFacts(page);
  expect(after.events - before.events).toBeGreaterThan(1);
});

test('applies a classified trackpad wheel in one rendered state', async ({ page }) => {
  await openSmoothViewer(page);
  const before = await scrollFacts(page);
  // Exercising both axes gives the source classifier an immediate score of 1;
  // predominant-axis routing then keeps Y and yields a 3px integer move.
  const prevented = await page.evaluate(() => {
    const event = new WheelEvent('wheel', {
      deltaX: 1,
      deltaY: 2.37,
      deltaMode: 0,
      bubbles: true,
      cancelable: true,
    });
    document.querySelector('.overflow-guard').dispatchEvent(event);
    return event.defaultPrevented;
  });
  expect(prevented).toBeTruthy();
  await expect.poll(async () => (await scrollFacts(page)).top).toBe(before.top + 3);
  const after = await scrollFacts(page);
  expect(after.events - before.events).toBe(1);
});

test('drags the editor scrollbar thumb through real pointer input', async ({ page }) => {
  await openSmoothViewer(page);
  const editorScrollable = page.locator(
    '.monaco-scrollable-element.editor-scrollable',
  );
  const verticalBar = editorScrollable.locator('> .scrollbar.vertical');
  await editorScrollable.hover();
  await expect(verticalBar).toHaveClass(/(^|\s)visible(\s|$)/);

  const { thumb, geometry: before } = await stableVerticalThumb(page);
  const beforeScroll = await scrollFacts(page);
  const remainingTravel =
    before.trackTop + before.trackHeight - before.thumbTop - before.thumbHeight;
  const dragDistance = Math.min(40, Math.max(8, remainingTravel / 2));
  const pointerX = before.thumbLeft + before.thumbWidth / 2;
  const pointerY = before.thumbTop + before.thumbHeight / 2;

  await page.mouse.move(pointerX, pointerY);
  await page.mouse.down();
  try {
    await expect(thumb).toHaveClass(/(^|\s)active(\s|$)/);
    await page.mouse.move(pointerX, pointerY + dragDistance, { steps: 4 });
  } finally {
    await page.mouse.up();
  }

  await expect
    .poll(async () => (await scrollFacts(page)).top)
    .toBeGreaterThan(beforeScroll.top);
  await expect
    .poll(async () => (await thumb.boundingBox())?.y ?? before.thumbTop)
    .toBeGreaterThan(before.thumbTop);
  const afterScroll = await scrollFacts(page);
  expect(afterScroll.events).toBeGreaterThan(beforeScroll.events);
  await expect(thumb).not.toHaveClass(/(^|\s)active(\s|$)/);
});
