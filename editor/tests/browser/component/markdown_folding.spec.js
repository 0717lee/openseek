import { expect, test } from '../support/test.js';
import {
  expectMoonBitReportPassed,
  installMoonBitReporter,
} from '../support/moonbit_reporter.js';

const host = '.markdown-folding-host';
const root = `${host} > .moonbit-viewer-markdown-document`;
const viewport = `${root} > .moonbit-viewer-markdown-document-viewport`;
const article = `${viewport} > .moonbit-viewer-markdown-document-article`;
const overlays = `${root} > .moonbit-viewer-markdown-document-overlays`;
const hoverWidget = `${overlays} .moonbit-viewer-markdown-hover-widget`;
const toggle = `${article} .moonbit-viewer-markdown-fold-toggle`;

async function openFoldingScenario(page, testInfo) {
  const reporter = await installMoonBitReporter(page);
  await page.goto('/browser-tests/component.html?markdownFolding=1');
  await page.waitForFunction(() =>
    Boolean(globalThis.__markdownFoldingControls),
  );
  const report = await reporter.waitForReport(testInfo, {
    suite: 'markdown_folding',
  });
  expectMoonBitReportPassed(report, { suite: 'markdown_folding' });
  expect(report.metrics.initialCollapsedCount).toBe(1);
  return report;
}

function foldFacts(page) {
  return page.evaluate(() =>
    globalThis.__markdownFoldingControls.getFoldFacts(),
  );
}

function hoverCalls(page) {
  return page.evaluate(() =>
    globalThis.__markdownFoldingControls.getHoverCalls(),
  );
}

function projectionGeneration(page) {
  return page
    .locator(root)
    .getAttribute('data-markdown-projection-generation');
}

function visibleByText(page, text) {
  return page.locator(`${article} > *`, { hasText: text }).first()
    .evaluate((node) => getComputedStyle(node).display !== 'none');
}

async function moveToSourceText(page, text, utf16Delta = 0) {
  const point = await page.locator(article).evaluate(
    (articleNode, { text, utf16Delta }) => {
      const walker = document.createTreeWalker(
        articleNode,
        NodeFilter.SHOW_TEXT,
      );
      let node;
      while ((node = walker.nextNode())) {
        const index = String(node.textContent || '').indexOf(text);
        if (index < 0) continue;
        node.parentElement?.scrollIntoView({ block: 'center' });
        const range = document.createRange();
        const boundary = Math.min(
          index + utf16Delta,
          String(node.textContent || '').length,
        );
        range.setStart(node, boundary);
        range.setEnd(
          node,
          Math.min(boundary + 1, String(node.textContent || '').length),
        );
        const rect = range.getBoundingClientRect();
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
      }
      throw new Error(`text node not found: ${text}`);
    },
    { text, utf16Delta },
  );
  // Two-step move with jitter: a move to coordinates the pointer already
  // occupies emits no mousemove, and the bridge only requests on real events.
  await page.mouse.move(point.x + 14, point.y + 6);
  await page.mouse.move(point.x, point.y, { steps: 2 });
  return point;
}

async function releaseLatestHover(page, expectedCount, outcome) {
  await page.waitForFunction(
    (count) =>
      globalThis.__markdownFoldingControls.getHoverCalls().length >= count,
    expectedCount,
    { timeout: 4_000 },
  );
  const calls = await hoverCalls(page);
  expect(calls.length).toBe(expectedCount);
  await page.evaluate(
    ({ id, outcome }) =>
      globalThis.__markdownFoldingControls.releaseHover(id, outcome),
    { id: calls[calls.length - 1].id, outcome },
  );
  return calls[calls.length - 1];
}

test('auto-fold seeds the bulky deep section and real clicks fold and reveal', async ({ page }, testInfo) => {
  await openFoldingScenario(page, testInfo);
  const facts = await foldFacts(page);
  expect(facts.collapsed).toEqual([facts.deep]);
  // The seeded collapse is real layout removal, not decoration.
  await expect.poll(() => visibleByText(page, 'deep three')).toBe(false);
  await expect.poll(() => visibleByText(page, 'alpha prose')).toBe(true);

  // Every foldable heading carries one accessible control.
  await expect(page.locator(toggle)).toHaveCount(4);
  const deepToggle = page.locator(`${toggle}[data-collapsed="true"]`);
  await expect(deepToggle).toHaveAttribute('aria-expanded', 'false');

  const generationBefore = await projectionGeneration(page);

  // A real click expands the seeded section...
  await deepToggle.click();
  await expect.poll(() => visibleByText(page, 'deep three')).toBe(true);
  expect((await foldFacts(page)).collapsed).toEqual([]);

  // ...and a real click on Alpha's toggle collapses Alpha, hiding its fence
  // while Beta's fence stays live for semantic hover.
  const alphaToggle = page.locator(toggle).nth(1);
  await alphaToggle.click();
  await expect(alphaToggle).toHaveAttribute('aria-expanded', 'false');
  await expect.poll(() => visibleByText(page, 'alpha_answer')).toBe(false);
  await expect.poll(() => visibleByText(page, 'beta_answer')).toBe(true);

  await moveToSourceText(page, 'beta_answer', 2);
  await releaseLatestHover(page, 1, 'sibling section hover');
  await expect(page.locator(hoverWidget)).toContainText(
    'sibling section hover',
  );
  await expect(page.locator(hoverWidget)).toBeVisible();

  // Expanding Alpha brings its fence straight back to hover life -- and the
  // whole fold conversation never re-parsed the document.
  await page.mouse.move(5, 5);
  await alphaToggle.click();
  await expect.poll(() => visibleByText(page, 'alpha_answer')).toBe(true);
  await moveToSourceText(page, 'alpha_answer', 2);
  await releaseLatestHover(page, 2, 'revealed fence hover');
  await expect(page.locator(hoverWidget)).toContainText(
    'revealed fence hover',
  );
  expect(await projectionGeneration(page)).toBe(generationBefore);
});



const tocBar = `${root} > .moonbit-viewer-markdown-toc`;
const tocToggle = `${tocBar} .moonbit-viewer-markdown-toc-toggle`;
const tocRow = `${tocBar} .moonbit-viewer-markdown-toc-row`;

test('the pinned toc bar outlines sections and navigation expands the chain', async ({ page }, testInfo) => {
  await openFoldingScenario(page, testInfo);
  const facts = await foldFacts(page);

  // Rendered, collapsed to the summary row, and outside the article.
  await expect(page.locator(tocBar)).toHaveAttribute('data-toc-visible', 'true');
  await expect(page.locator(tocToggle)).toHaveText('Contents · 4');
  await expect(page.locator(tocToggle)).toHaveAttribute(
    'aria-label',
    'Contents, 4 sections',
  );
  await expect(page.locator(tocRow).first()).toBeHidden();
  const collapsedTocBox = await page.locator(tocBar).boundingBox();
  const rootBox = await page.locator(root).boundingBox();
  const titleBox = await page.locator(`${article} > h1`).boundingBox();
  expect(collapsedTocBox).not.toBeNull();
  expect(rootBox).not.toBeNull();
  expect(titleBox).not.toBeNull();
  expect(collapsedTocBox.x).toBeGreaterThan(rootBox.x);
  expect(collapsedTocBox.width).toBeLessThan(rootBox.width / 2);
  expect(titleBox.y).toBeGreaterThanOrEqual(
    collapsedTocBox.y + collapsedTocBox.height - 1,
  );

  // Expanding shows one row per section, indented by structural depth.
  await page.locator(tocToggle).click();
  await expect(page.locator(tocToggle)).toHaveAttribute('aria-expanded', 'true');
  await expect(page.locator(tocRow)).toHaveCount(4);
  await expect(page.locator(tocRow).nth(3)).toHaveAttribute('data-toc-depth', '3');
  const expandedTocBox = await page.locator(tocBar).boundingBox();
  expect(expandedTocBox).not.toBeNull();
  expect(expandedTocBox.width).toBeLessThanOrEqual(321);
  expect(expandedTocBox.x + expandedTocBox.width).toBeLessThanOrEqual(
    rootBox.x + rootBox.width - 7,
  );

  // Keyboard navigation to a middle section collapses the overlay, restores
  // focus to its persistent toggle, and honors the viewport scroll inset.
  const betaRow = page.locator(tocRow, { hasText: 'Beta' });
  await betaRow.focus();
  await betaRow.press('Enter');
  await expect(page.locator(tocToggle)).toHaveAttribute(
    'aria-expanded',
    'false',
  );
  await expect(page.locator(tocToggle)).toBeFocused();
  const betaVisible = await page.locator(`${article} > h2`, { hasText: 'Beta' })
    .evaluate((node) => {
      const rect = node.getBoundingClientRect();
      const toc = node
        .closest('.moonbit-viewer-markdown-document')
        .querySelector('.moonbit-viewer-markdown-toc')
        .getBoundingClientRect();
      return rect.top >= toc.bottom - 1;
    });
  expect(betaVisible).toBe(true);

  await page.locator(tocToggle).click();
  await expect(page.locator(tocToggle)).toHaveAttribute('aria-expanded', 'true');

  // The Deep section starts auto-collapsed; clicking its row expands it and
  // scrolls its heading into the viewport.
  expect(facts.collapsed).toEqual([facts.deep]);
  await page.locator(tocRow, { hasText: 'Deep' }).click();
  await expect(page.locator(tocToggle)).toHaveAttribute(
    'aria-expanded',
    'false',
  );
  await expect(page.locator(tocRow).first()).toBeHidden();
  await expect.poll(() => visibleByText(page, 'deep three')).toBe(true);
  expect((await foldFacts(page)).collapsed).toEqual([]);
  const deepVisible = await page.locator(`${article} > h3`, { hasText: 'Deep' })
    .evaluate((node) => {
      const rect = node.getBoundingClientRect();
      const viewport = node.closest('.moonbit-viewer-markdown-document-viewport')
        .getBoundingClientRect();
      const toc = node
        .closest('.moonbit-viewer-markdown-document')
        .querySelector('.moonbit-viewer-markdown-toc')
        .getBoundingClientRect();
      return {
        insideViewport:
          rect.top >= viewport.top - 1 && rect.top <= viewport.bottom,
        belowCollapsedToc: rect.top >= toc.bottom - 1,
      };
    });
  expect(deepVisible).toEqual({
    insideViewport: true,
    belowCollapsedToc: true,
  });

  // A revealed-by-navigation fence hovers, and the fold conversation still
  // never re-parsed the document.
  const generation = await projectionGeneration(page);
  await moveToSourceText(page, 'beta_answer', 2);
  await releaseLatestHover(page, 1, 'post-navigation hover');
  await expect(page.locator(hoverWidget)).toContainText('post-navigation hover');
  expect(await projectionGeneration(page)).toBe(generation);

  // This real-browser assertion owns both the two-section visibility policy
  // and its CSS consequence: a hidden bar must not reserve the visible-TOC
  // title clearance.
  await page.locator(tocBar).evaluate((node) =>
    node.setAttribute('data-toc-visible', 'false'),
  );
  await expect(page.locator(tocBar)).toBeHidden();
  await expect(page.locator(article)).toHaveCSS('padding-top', '16px');
});

test('toc navigation scrolls only the Markdown viewport', async ({
  page,
}, testInfo) => {
  await openFoldingScenario(page, testInfo);
  // Keep the Viewer below the browser viewport without pre-scrolling the page.
  // Programmatic activation avoids Playwright scrolling the button itself.
  await page.locator('.markdown-folding-shell').evaluate((shell) => {
    shell.style.paddingTop = '720px';
  });
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  const markdownScrollBefore = await page.locator(viewport).evaluate(
    (node) => node.scrollTop,
  );

  await page.locator(tocToggle).evaluate((button) => button.click());
  await page.locator(tocRow, { hasText: 'Deep' }).evaluate((button) =>
    button.click(),
  );

  await expect
    .poll(() => page.locator(viewport).evaluate((node) => node.scrollTop))
    .toBeGreaterThan(markdownScrollBefore);
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
});
