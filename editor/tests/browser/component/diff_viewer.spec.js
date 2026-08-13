import { expect, test } from '../support/test.js';
import {
  expectMoonBitReportPassed,
  installMoonBitReporter,
} from '../support/moonbit_reporter.js';

const root = '.diff-viewer-host';
const original = `${root} .moonbit-diff-editor-original`;
const modified = `${root} .moonbit-diff-editor-modified`;
const visibleHover =
  '[data-content-widget="editor.contrib.resizableContentHoverWidget"] .monaco-hover:not(.hidden)';

async function textPoint(locator, needle) {
  return locator.evaluate((node, value) => {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      const index = text.textContent.indexOf(value);
      if (index < 0) continue;
      const range = document.createRange();
      range.setStart(text, index);
      range.setEnd(text, index + value.length);
      const rect = range.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    }
    return null;
  }, needle);
}

test('DiffViewer aligns two ordinary Viewers and keeps language features revision-aware', async ({
  page,
}, testInfo) => {
  const reporter = await installMoonBitReporter(page);
  await page.goto('/browser-tests/component.html?diffViewer=1');
  const report = await reporter.waitForReport(testInfo, {
    suite: 'diff_viewer',
    timeout: 10_000,
  });
  expectMoonBitReportPassed(report, { suite: 'diff_viewer' });
  expect(report.metrics.paneCount).toBe(2);
  expect(report.metrics.rootWidth).toBeGreaterThanOrEqual(899);
  expect(report.metrics.rootHeight).toBeGreaterThanOrEqual(319);
  expect(report.metrics.paneWidth).toBeGreaterThanOrEqual(449);
  expect(report.metrics.paneHeight).toBeGreaterThanOrEqual(319);
  expect(report.metrics.changedDecorationCount).toBeGreaterThanOrEqual(2);
  expect(report.metrics.alignmentZoneCount).toBeGreaterThanOrEqual(1);

  await expect(page.locator(`${original} .monaco-editor`)).toBeVisible();
  await expect(page.locator(`${modified} .monaco-editor`)).toBeVisible();
  await expect(page.locator(`${original} .diff-editor-line-delete`).first()).toBeVisible();
  await expect(page.locator(`${modified} .diff-editor-line-insert`).first()).toBeVisible();

  const originalAnchor = page.locator(`${original} .view-line`).filter({
    hasText: 'alignment_anchor',
  });
  const modifiedAnchor = page.locator(`${modified} .view-line`).filter({
    hasText: 'alignment_anchor',
  });
  await expect(originalAnchor).toBeVisible();
  await expect(modifiedAnchor).toBeVisible();
  const originalBox = await originalAnchor.boundingBox();
  const modifiedBox = await modifiedAnchor.boundingBox();
  expect(Math.abs(originalBox.y - modifiedBox.y)).toBeLessThanOrEqual(1);

  const modifiedSymbol = page.locator(`${modified} .view-line`).filter({
    hasText: 'live_answer',
  }).first();
  const modifiedPoint = await textPoint(modifiedSymbol, 'live_answer');
  expect(modifiedPoint).not.toBeNull();
  await page.mouse.move(modifiedPoint.x, modifiedPoint.y);
  await expect(page.locator(`${modified} ${visibleHover}`)).toContainText(
    'hover from the modified revision',
    { timeout: 5_000 },
  );

  await page.mouse.move(0, 0);
  await expect(page.locator(visibleHover)).toHaveCount(0);
  const originalSymbol = page.locator(`${original} .view-line`).filter({
    hasText: 'live_answer',
  }).first();
  const originalPoint = await textPoint(originalSymbol, 'live_answer');
  expect(originalPoint).not.toBeNull();
  await page.mouse.move(originalPoint.x, originalPoint.y);
  await page.waitForTimeout(450);
  await expect(page.locator(`${original} ${visibleHover}`)).toHaveCount(0);

  const modifiedEditorBox = await page.locator(`${modified} .monaco-editor`).boundingBox();
  await page.mouse.move(
    modifiedEditorBox.x + modifiedEditorBox.width / 2,
    modifiedEditorBox.y + modifiedEditorBox.height / 2,
  );
  await page.mouse.wheel(0, 620);
  await expect
    .poll(async () => {
      const [left, right] = await Promise.all([
        page.locator(`${original} .view-line`).first().getAttribute('data-line'),
        page.locator(`${modified} .view-line`).first().getAttribute('data-line'),
      ]);
      return { left, right };
    })
    .not.toEqual({ left: '1', right: '1' });

  const sharedOriginal = page.locator(`${original} .view-line`).filter({
    hasText: 'shared_line_40',
  });
  const sharedModified = page.locator(`${modified} .view-line`).filter({
    hasText: 'shared_line_40',
  });
  await expect(sharedOriginal).toBeVisible();
  await expect(sharedModified).toBeVisible();
  const sharedOriginalBox = await sharedOriginal.boundingBox();
  const sharedModifiedBox = await sharedModified.boundingBox();
  expect(Math.abs(sharedOriginalBox.y - sharedModifiedBox.y)).toBeLessThanOrEqual(1);

  const definitionReference = page.locator(`${modified} .view-line`).filter({
    hasText: 'use_live_answer',
  });
  await expect(definitionReference).toBeVisible();
  const definitionPoint = await textPoint(definitionReference, 'live_answer');
  await page.mouse.click(definitionPoint.x, definitionPoint.y);
  await page.keyboard.press('F12');
  await expect(page.locator(`${modified} .view-line[data-line="1"]`)).toBeVisible();
  await expect(page.locator(`${original} .view-line[data-line="1"]`)).toBeVisible();
});
