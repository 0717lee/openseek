import { expect, gotoBrowserScenario, test } from '../support/test.js';
import {
  expectMoonBitReportPassed,
  installMoonBitReporter,
} from '../support/moonbit_reporter.js';

// End-to-end coverage for the folding contrib: the MoonBit scenario
// (tests/browser/moonbit/folding) asserts the initial render (expanded
// chevrons in the .cldr lane), then this spec drives the real interactions —
// a chevron click folds the region out of the view axis (collapsed chevron,
// inline-folded `⋯`, skipped line numbers), a second click unfolds, and
// Ctrl/Cmd+Shift+[ folds at the cursor.
//
// NOTE: view-line text uses non-breaking spaces, so text needles must be
// space-free.

const editor = '.monaco-editor.readonly-editor';

test('folding: chevron click folds and unfolds, keyboard folds at cursor', async ({ page }, testInfo) => {
  const reporter = await installMoonBitReporter(page);
  try {
    await gotoBrowserScenario(page, 'folding');
    await expect(page.locator(editor)).toContainText('fold_child_a', {
      timeout: 10_000,
    });
    const report = await reporter.waitForReport(testInfo, { suite: 'folding' });
    expectMoonBitReportPassed(report, { suite: 'folding' });

    const expandedChevrons = page.locator(
      '.margin-view-overlays .cldr.codicon-folding-expanded',
    );
    const collapsedChevrons = page.locator(
      '.margin-view-overlays .cldr.codicon-folding-collapsed',
    );
    await expect(expandedChevrons).toHaveCount(2);

    // Fold the first region (lines 1-3) through the same hover-reveal and
    // trusted click path used by a user.
    await expandedChevrons.first().hover();
    await expandedChevrons.first().click();

    // Lines 2-3 leave the view axis; the second region is untouched.
    await expect(page.locator(editor)).not.toContainText('fold_child_a');
    await expect(page.locator(editor)).not.toContainText('fold_child_b');
    await expect(page.locator(editor)).toContainText('fold_top');
    await expect(page.locator(editor)).toContainText('fold_tail');
    await expect(collapsedChevrons).toHaveCount(1);
    await expect(expandedChevrons).toHaveCount(1);

    // The folded header renders the `inline-folded` ⋯ pseudo-element carrier
    // and the folded-background whole-line highlight.
    await expect(page.locator(`${editor} .inline-folded`)).toHaveCount(1);
    await expect(page.locator(`${editor} .folded-background`)).toHaveCount(1);

    // Line numbers skip the folded model lines: 1, 4, 5.
    const numbers = await page
      .locator('.margin-view-overlays .line-numbers')
      .allInnerTexts();
    expect(numbers.map((n) => n.trim()).filter(Boolean)).toEqual(['1', '4', '5']);

    // The folded header's generated ellipsis is a real mouse contract too:
    // clicking its measured right edge unfolds without using the gutter.
    const ellipsisBox = await page
      .locator(`${editor} .inline-folded`)
      .boundingBox();
    expect(ellipsisBox).not.toBeNull();
    await page.mouse.click(
      ellipsisBox.x + ellipsisBox.width - 2,
      ellipsisBox.y + ellipsisBox.height / 2,
    );
    await expect(page.locator(editor)).toContainText('fold_child_a');
    await expect(collapsedChevrons).toHaveCount(0);
    await expect(expandedChevrons).toHaveCount(2);
    await expect(page.locator(`${editor} .inline-folded`)).toHaveCount(0);

    // Keyboard: put the cursor inside the second region and fold it with
    // Ctrl/Cmd+Shift+[ (editor.fold → setCollapseStateUp).
    await page.locator(`${editor} .view-line`, { hasText: 'fold_tail' }).click();
    await page.keyboard.press('ControlOrMeta+Shift+[');
    await expect(page.locator(editor)).not.toContainText('fold_tail');
    await expect(collapsedChevrons).toHaveCount(1);

    // ... and unfold it again with Ctrl/Cmd+Shift+].
    await page.keyboard.press('ControlOrMeta+Shift+]');
    await expect(page.locator(editor)).toContainText('fold_tail');
    await expect(collapsedChevrons).toHaveCount(0);
  } finally {
    reporter.dispose();
  }
});
