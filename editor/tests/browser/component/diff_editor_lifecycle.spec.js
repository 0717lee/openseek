import { expect, test } from '../support/test.js';

test('owns and tears down exactly two kernels and one shared diff view model', async ({ page }) => {
  await page.goto('/browser-tests/component.html?diffLifecycle=1');
  await page.waitForFunction(() => Boolean(globalThis.__diffEditorLifecycleControls));

  const root = page.locator('.diff-lifecycle-host > .moonbit-diff-editor');
  await expect(root).toHaveCount(1);
  await expect(root.locator('.moonbit-diff-editor-pane > .monaco-editor')).toHaveCount(2);
  await expect(
    root.locator('.diff-editor-inline-deleted-block'),
  ).toHaveCount(1);

  const overview = root.locator('.moonbit-diff-overview');
  const overviewViewport = overview.locator('.moonbit-diff-overview-viewport');
  const overviewCanvases = overview.locator('.diffOverviewRuler');
  await expect(overview).toBeVisible();
  await expect(overviewCanvases).toHaveCount(2);
  await expect(
    overview.locator('[data-diff-overview-side="original"]'),
  ).toHaveCSS('width', '15px');
  await expect(
    overview.locator('[data-diff-overview-side="modified"]'),
  ).toHaveCSS('width', '15px');
  await expect(overview).toHaveCSS('width', '30px');
  const reservedLayout = await root.evaluate((node) => ({
    root: node.getBoundingClientRect().width,
    panes: node.querySelector('.moonbit-diff-editor-panes')
      ?.getBoundingClientRect().width,
  }));
  expect(reservedLayout.root - reservedLayout.panes).toBe(30);

  const modifiedOverview = overview.locator(
    '[data-diff-overview-side="modified"]',
  );
  const originalOverview = overview.locator(
    '[data-diff-overview-side="original"]',
  );
  await expect
    .poll(async () => Number(await modifiedOverview.getAttribute(
      'data-overview-ruler-scroll-height',
    )))
    .toBeGreaterThan(420);
  const originalScrollHeight = Number(await originalOverview.getAttribute(
    'data-overview-ruler-scroll-height',
  ));
  // In Inline mode the hidden original editor is the geometry source for its
  // overview ruler. It must stay laid out with wrapping disabled, just like
  // VS Code, even when the visible modified editor wraps long deleted lines.
  expect(originalScrollHeight).toBeGreaterThan(6000);
  expect(originalScrollHeight).toBeLessThan(8000);
  await page.locator('.diff-lifecycle-host').evaluate((node) => {
    node.style.width = '520px';
  });
  await expect
    .poll(async () => Number(await originalOverview.getAttribute(
        'data-overview-ruler-scroll-height',
      )))
    .toBe(originalScrollHeight);
  const expandedScrollHeight = Number(await modifiedOverview.getAttribute(
    'data-overview-ruler-scroll-height',
  ));
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_hide_unchanged(true),
  );
  await expect
    .poll(async () => Number(await modifiedOverview.getAttribute(
      'data-overview-ruler-scroll-height',
    )))
    .toBeLessThan(expandedScrollHeight - 1000);
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_hide_unchanged(false),
  );
  await expect
    .poll(async () => Number(await modifiedOverview.getAttribute(
      'data-overview-ruler-scroll-height',
    )))
    .toBeGreaterThanOrEqual(expandedScrollHeight);
  const initialScrollTop = Number(await modifiedOverview.getAttribute(
    'data-overview-ruler-scroll-top',
  ));
  await overview.hover();
  await page.mouse.wheel(0, 600);
  await expect
    .poll(async () => Number(await modifiedOverview.getAttribute(
      'data-overview-ruler-scroll-top',
    )))
    .toBeGreaterThan(initialScrollTop);
  await expect
    .poll(async () => Number(await overviewViewport.getAttribute(
      'data-diff-viewport-top',
    )))
    .toBeGreaterThan(0);

  const overviewBox = await overview.boundingBox();
  expect(overviewBox).not.toBeNull();
  const viewportBox = await overviewViewport.boundingBox();
  expect(viewportBox).not.toBeNull();
  await page.mouse.move(
    overviewBox.x + overviewBox.width / 2,
    overviewBox.y + overviewBox.height - 2,
  );
  const trackBackground = await overviewViewport.evaluate((node) =>
    getComputedStyle(node).backgroundColor,
  );
  await page.mouse.move(
    viewportBox.x + viewportBox.width / 2,
    viewportBox.y + viewportBox.height / 2,
  );
  const hoverBackground = await overviewViewport.evaluate((node) =>
    getComputedStyle(node).backgroundColor,
  );
  expect(hoverBackground).not.toBe(trackBackground);
  await page.mouse.down();
  const activeBackground = await overviewViewport.evaluate((node) =>
    getComputedStyle(node).backgroundColor,
  );
  expect(activeBackground).not.toBe(hoverBackground);
  await page.mouse.up();
  await page.mouse.click(
    overviewBox.x + overviewBox.width / 2,
    overviewBox.y + overviewBox.height - 12,
  );
  const afterTrackClick = Number(await modifiedOverview.getAttribute(
    'data-overview-ruler-scroll-top',
  ));
  expect(afterTrackClick).toBeGreaterThan(initialScrollTop);
  await page.mouse.move(
    overviewBox.x + overviewBox.width / 2,
    overviewBox.y + overviewBox.height - 12,
  );
  await page.mouse.down();
  await page.mouse.move(
    overviewBox.x + overviewBox.width / 2,
    overviewBox.y + 40,
    { steps: 4 },
  );
  await page.mouse.up();
  await expect
    .poll(async () => Number(await modifiedOverview.getAttribute(
      'data-overview-ruler-scroll-top',
    )))
    .toBeLessThan(afterTrackClick);

  await expect
    .poll(() =>
      page.evaluate(() =>
        globalThis.__diffEditorLifecycleControls.snapshot(),
      ),
    )
    .toMatchObject({
      kernelCount: 2,
      kernelsAreDistinct: true,
      viewModelCount: 1,
      widgetDisposed: false,
      disposePassCount: 0,
      originalKernelDisposed: false,
      modifiedKernelDisposed: false,
      viewModelDisposed: false,
      modelPairIsCommitting: false,
      committedModelGeneration: 1,
      overviewRulerPresent: true,
      overviewRulerDisposed: false,
      inlineDeletedZoneCount: 1,
      resizeObserverPresent: true,
      resizeObserverDisposed: false,
      afterRenderWaiterCount: 0,
      afterRenderRemaining: 0,
      viewModelPendingSchedulerCount: 0,
    });

  const before = await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.snapshot(),
  );
  expect(before.originalKernelId).not.toBe(before.modifiedKernelId);
  expect(before.inlineDeletedZoneCount).toBeGreaterThan(0);

  const status = root.locator('.moonbit-diff-editor-status');
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_provider('provider'),
  );
  await expect(root).toHaveAttribute('data-diff-failure', 'provider error');
  await expect(status).toBeVisible();
  await expect(status).toHaveText('Unable to compute this diff.');
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_provider('validator'),
  );
  await expect(root).toHaveAttribute(
    'data-diff-failure',
    'validator rejection',
  );
  await expect(status).toHaveText(
    'The diff provider returned an invalid result.',
  );
  const clearedFailure = await page.evaluate(() => {
    globalThis.__diffEditorLifecycleControls.set_model_attached(false);
    const editor = document.querySelector(
      '.diff-lifecycle-host > .moonbit-diff-editor',
    );
    const diagnostic = editor.querySelector('.moonbit-diff-editor-status');
    return {
      failurePresent: editor.hasAttribute('data-diff-failure'),
      diagnosticHidden: diagnostic.hasAttribute('hidden'),
    };
  });
  expect(clearedFailure).toEqual({
    failurePresent: false,
    diagnosticHidden: true,
  });
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_provider('core'),
  );
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_model_attached(true),
  );
  await expect(root).not.toHaveAttribute('data-diff-failure');
  await expect(status).toBeHidden();
  await expect
    .poll(() =>
      page.evaluate(() =>
        globalThis.__diffEditorLifecycleControls.snapshot().diffUpToDate,
      ),
    )
    .toBe(true);

  await page.evaluate(() => globalThis.__diffEditorLifecycleControls.dispose());
  await expect(root).toHaveCount(0);
  await expect(page.locator('.diff-lifecycle-host .monaco-editor')).toHaveCount(0);

  const afterFirstDispose = await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.snapshot(),
  );
  expect(afterFirstDispose).toMatchObject({
    kernelCount: 2,
    kernelsAreDistinct: true,
    viewModelCount: 1,
    widgetDisposed: true,
    disposePassCount: 1,
    originalKernelDisposed: true,
    modifiedKernelDisposed: true,
    viewModelDisposed: true,
    modelPairIsCommitting: false,
    overviewRulerPresent: false,
    overviewRulerDisposed: true,
    inlineDeletedZoneCount: 0,
    resizeObserverPresent: false,
    resizeObserverDisposed: true,
    afterRenderWaiterCount: 0,
    afterRenderRemaining: 0,
    viewModelPendingSchedulerCount: 0,
    lifetimeSubscriptionCount: 0,
  });

  await page.evaluate(() => globalThis.__diffEditorLifecycleControls.dispose());
  const afterSecondDispose = await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.snapshot(),
  );
  expect(afterSecondDispose).toEqual(afterFirstDispose);
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.dispose_models(),
  );
});
