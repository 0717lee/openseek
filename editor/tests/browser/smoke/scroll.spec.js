import { promises as fs } from 'node:fs';
import { expect, test } from '../support/test.js';
import {
  collectReadonlyEvents,
  lastScrollTop,
  openWorkspaceFile,
} from '../support/app.js';

const largeFixture = 'tests/fixtures/workspace/src/generated_scroll.mbt';

test.beforeAll(async () => {
  const chunks = [];
  for (let i = 0; i < 2000; i++) {
    chunks.push(`///|\npub fn generated_value_${i}() -> Int {\n  ${i}\n}\n`);
  }
  await fs.writeFile(largeFixture, chunks.join('\n'), 'utf8');
});

test.afterAll(async () => {
  await fs.rm(largeFixture, { force: true });
});

test('reveals the editor scrollbar without scroll shadows then fades it after idle', async ({
  page,
}) => {
  const events = collectReadonlyEvents(page);
  await page.goto('/');
  await openWorkspaceFile(page, 'src/generated_scroll.mbt', { waitForActiveReveal: false });

  const editorScrollable = page.locator('.monaco-scrollable-element.editor-scrollable');
  const verticalBar = editorScrollable.locator('> .scrollbar.vertical');
  await expect(verticalBar).toHaveClass(/(^|\s)invisible(\s|$)/);
  await editorScrollable.hover();
  await expect(verticalBar).toHaveClass(/(^|\s)visible(\s|$)/);

  const scrollEventsBefore = events.count('view:scroll');
  await page.mouse.wheel(0, 720);
  await expect
    .poll(() => lastScrollTop(events), { timeout: 3_000 })
    .toBeGreaterThan(0);
  expect(events.count('view:scroll')).toBeGreaterThan(scrollEventsBefore);
  await expect(editorScrollable.locator('> .shadow')).toHaveCount(0);
  await expect(verticalBar).toHaveClass(/(^|\s)visible(\s|$)/);

  await page.mouse.move(4, 4);
  await expect(verticalBar).toHaveClass(/(^|\s)invisible(\s|$).*($|\s)fade(\s|$)/, {
    timeout: 1_500,
  });
});

test('scrolls wheel input through the Monaco delta pipeline at integer positions', async ({ page }) => {
  const events = collectReadonlyEvents(page);
  await page.goto('/');
  await openWorkspaceFile(page, 'src/generated_scroll.mbt', { waitForActiveReveal: false });

  const editorScrollable = page.locator('.monaco-scrollable-element.editor-scrollable');
  await editorScrollable.hover();
  // `StandardWheelEvent` (`deltaY / 40`) x `SCROLL_WHEEL_SENSITIVITY` (50):
  // a 72px pixel-mode wheel delta scrolls 90px, 1.25x, like Monaco.
  await page.mouse.wheel(0, 72);
  await expect.poll(() => lastScrollTop(events), { timeout: 3_000 }).toBe(90);

  // The shared lines-content rail stays on whole-pixel top/left properties;
  // projected layers do not add their own transforms.
  const rail = await page.evaluate(() => {
    const linesContent = document.querySelector('.lines-content');
    return {
      top: linesContent.style.top,
      left: linesContent.style.left,
      viewLinesTransform: document.querySelector('.view-lines').style.transform,
      zonesTransform: document.querySelector('.view-zones').style.transform,
      widgetsTransform: document.querySelector('.contentWidgets').style.transform,
      cursorsTransform: document.querySelector('.cursors-layer').style.transform,
    };
  });
  expect(rail.top).toMatch(/^-?\d+px$/);
  expect(rail.left).toMatch(/^-?\d+px$/);
  expect(rail.viewLinesTransform).toBe('');
  expect(rail.zonesTransform).toBe('');
  expect(rail.widgetsTransform).toBe('');
  expect(rail.cursorsTransform).toBe('');
});
