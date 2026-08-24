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
