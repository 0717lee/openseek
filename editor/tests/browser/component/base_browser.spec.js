import { expect, gotoBrowserScenario, test } from '../support/test.js';
import {
  expectMoonBitReportPassed,
  installMoonBitReporter,
} from '../support/moonbit_reporter.js';

async function openBaseBrowserScenario(page, testInfo) {
  const reporter = await installMoonBitReporter(page);
  try {
    await gotoBrowserScenario(page, 'base-browser');
    const report = await reporter.waitForReport(testInfo, {
      suite: 'base_browser',
    });
    expectMoonBitReportPassed(report, { suite: 'base_browser' });
    await expect(page.locator('#base-browser-fixture')).toHaveAttribute(
      'data-ready',
      'true',
    );
  } finally {
    reporter.dispose();
  }
}

async function dispatchFromFirstChild(locator, type) {
  await locator.evaluate((element, eventType) => {
    element.firstChild.dispatchEvent(
      new Event(eventType, { bubbles: true, cancelable: true }),
    );
  }, type);
}

async function setNativeSelection(
  page,
  anchorId,
  anchorOffset,
  focusId,
  focusOffset,
) {
  await page.evaluate(
    ({ anchorId: anchor, anchorOffset: start, focusId: focus, focusOffset: end }) => {
      const anchorNode = document.getElementById(anchor).firstChild;
      const focusNode = document.getElementById(focus).firstChild;
      const selection = document.getSelection();
      selection.removeAllRanges();
      selection.setBaseAndExtent(anchorNode, start, focusNode, end);
    },
    { anchorId, anchorOffset, focusId, focusOffset },
  );
}

async function pointerDownAtCenter(page, locator) {
  await locator.scrollIntoViewIfNeeded();
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  return box;
}

test('uses the iframe owner document and prevents focus scrolling', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const frame = page.frameLocator('#owner-document-frame');
  const scroller = frame.locator('#focus-scroller');

  await page.locator('#focus-without-scroll').click();

  await expect(page.locator('#focus-result')).toHaveAttribute(
    'data-contains-target',
    'true',
  );
  await expect(page.locator('#focus-result')).toHaveAttribute(
    'data-target-focused',
    'true',
  );
  await expect(page.locator('#focus-result')).toHaveAttribute(
    'data-contains-active',
    'true',
  );
  await expect(frame.locator('#focus-target')).toBeFocused();
  expect(await scroller.evaluate((element) => element.scrollTop)).toBe(120);
});

test('classifies real element and text-node event targets within a boundary', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const result = page.locator('#event-result');

  await page.locator('#event-boundary').dispatchEvent('ownership-probe');
  await expect(result).toHaveAttribute('data-target-is-boundary', 'true');
  await expect(result).toHaveAttribute('data-has-bounded-ancestor', 'false');

  await dispatchFromFirstChild(page.locator('#event-plain'), 'ownership-probe');
  await expect(result).toHaveAttribute('data-target-is-boundary', 'false');
  await expect(result).toHaveAttribute('data-has-bounded-ancestor', 'false');

  await dispatchFromFirstChild(
    page.locator('#event-owned-child'),
    'ownership-probe',
  );
  await expect(result).toHaveAttribute('data-has-bounded-ancestor', 'true');

  await dispatchFromFirstChild(
    page.locator('#event-outside-child'),
    'ownership-probe',
  );
  await expect(result).toHaveAttribute('data-has-bounded-ancestor', 'false');

  await dispatchFromFirstChild(
    page.locator('#event-owned-child'),
    'invalid-selector-probe',
  );
  await expect(result).toHaveAttribute('data-has-bounded-ancestor', 'false');
});

test('checks both endpoints of a real non-collapsed Selection', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const result = page.locator('#selection-result');
  const check = page.locator('#check-selection');

  await setNativeSelection(page, 'selection-plain', 0, 'selection-plain', 0);
  await check.evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-has-bounded-endpoint', 'false');

  await setNativeSelection(page, 'selection-plain', 0, 'selection-plain', 5);
  await check.evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-has-bounded-endpoint', 'false');

  await setNativeSelection(page, 'selection-plain', 0, 'selection-owned', 5);
  await check.evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-has-bounded-endpoint', 'true');

  await setNativeSelection(page, 'selection-owned', 5, 'selection-plain', 0);
  await check.evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-has-bounded-endpoint', 'true');

  await setNativeSelection(
    page,
    'selection-plain',
    0,
    'selection-outside-owned',
    5,
  );
  await check.evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-has-bounded-endpoint', 'false');

  await setNativeSelection(page, 'selection-plain', 0, 'selection-owned', 5);
  await page
    .locator('#check-selection-invalid')
    .evaluate((element) => element.click());
  await expect(result).toHaveAttribute('data-invalid-selector-matched', 'false');
});

test('captures a real pointer until pointerup and prevents monitored moves', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const target = page.locator('#pointer-capture-target');
  const box = await pointerDownAtCenter(page, target);

  await expect(target).toHaveAttribute('data-has-pointer-capture', 'true');
  await page.mouse.move(box.x + box.width + 80, box.y + box.height + 20, {
    steps: 3,
  });
  await expect.poll(() => target.getAttribute('data-moves')).not.toBe('0');
  await expect(target).toHaveAttribute('data-move-default-prevented', 'true');
  await page.mouse.up();
  await expect(target).toHaveAttribute('data-stops', '1');

  const movesAfterStop = await target.getAttribute('data-moves');
  await page.mouse.move(box.x + box.width + 120, box.y + box.height + 40);
  await expect(target).toHaveAttribute('data-moves', movesAfterStop);
});

test('falls back to the initial element owner window when capture fails', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const target = page
    .frameLocator('#pointer-owner-frame')
    .locator('#pointer-fallback-target');
  const box = await pointerDownAtCenter(page, target);

  await expect(target).toHaveAttribute('data-has-pointer-capture', 'false');
  await page.mouse.move(box.x + box.width + 70, box.y + 20, { steps: 3 });
  await expect.poll(() => target.getAttribute('data-moves')).not.toBe('0');
  await expect(target).toHaveAttribute('data-move-default-prevented', 'true');
  await page.mouse.up();
  await expect(target).toHaveAttribute('data-stops', '1');
});

test('restarts, stops, and permanently disposes the pointer monitor', async ({
  page,
}, testInfo) => {
  await openBaseBrowserScenario(page, testInfo);
  const target = page.locator('#pointer-lifecycle-target');
  const box = await pointerDownAtCenter(page, target);

  const pointerId = await target.getAttribute('data-pointer-id');
  await expect(target).toHaveAttribute('data-has-pointer-capture', 'true');
  await target.evaluate((element, id) => {
    element.releasePointerCapture(Number(id));
  }, pointerId);
  await page
    .locator('#pointer-stop-false')
    .evaluate((element) => element.click());
  await page.mouse.move(box.x + box.width + 50, box.y + 10);
  await expect(target).toHaveAttribute('data-moves', '0');
  await expect(target).toHaveAttribute('data-stops', '0');
  await page.mouse.up();

  await pointerDownAtCenter(page, target);
  await page.locator('#pointer-restart').evaluate((element) => element.click());
  await expect(target).toHaveAttribute('data-starts', '3');
  await page.mouse.move(box.x + box.width + 70, box.y + 20, { steps: 3 });
  await expect.poll(() => target.getAttribute('data-moves')).not.toBe('0');
  await page.locator('#pointer-stop-true').evaluate((element) => element.click());
  await expect(target).toHaveAttribute('data-stops', '1');
  const movesAfterStop = await target.getAttribute('data-moves');
  await page.mouse.move(box.x + box.width + 100, box.y + 30);
  await expect(target).toHaveAttribute('data-moves', movesAfterStop);
  await page.mouse.up();

  await page.locator('#pointer-dispose').evaluate((element) => element.click());
  await page.locator('#pointer-dispose').evaluate((element) => element.click());
  await pointerDownAtCenter(page, target);
  await page.mouse.move(box.x + box.width + 80, box.y + 20);
  await page.mouse.up();
  await expect(target).toHaveAttribute('data-moves', movesAfterStop);
  await expect(target).toHaveAttribute('data-stops', '1');
});
