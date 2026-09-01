import { expect, test } from '../support/test.js';

const diffLifecycleRoot =
  '.diff-lifecycle-host > .moonbit-diff-editor';

async function openDiffLifecycle(page) {
  await page.goto('/browser-tests/component.html?diffLifecycle=1');
  await page.waitForFunction(() =>
    Boolean(globalThis.__diffEditorLifecycleControls),
  );
  const root = page.locator(diffLifecycleRoot);
  await expect(root).toHaveCount(1);
  return root;
}

async function waitForAnimationFrames(page, count = 2) {
  await page.evaluate((frameCount) => new Promise((resolve) => {
    let remaining = frameCount;
    const advance = () => {
      remaining -= 1;
      if (remaining <= 0) {
        resolve();
      } else {
        requestAnimationFrame(advance);
      }
    };
    requestAnimationFrame(advance);
  }), count);
}

async function waitForDiffLifecycleIdle(page) {
  await waitForAnimationFrames(page);
  await expect
    .poll(() => page.evaluate(() =>
      globalThis.__diffEditorLifecycleControls.snapshot(),
    ))
    .toMatchObject({
      modelPairIsCommitting: false,
      afterRenderWaiterCount: 0,
      afterRenderRemaining: 0,
      viewModelPendingSchedulerCount: 0,
      diffUpToDate: true,
    });
}

async function setDiffLifecycleFixture(page, fixture) {
  await page.evaluate((value) =>
    globalThis.__diffEditorLifecycleControls.set_fixture(value), fixture,
  );
}

async function setDiffLifecycleOptions(
  page,
  { layout, renderIndicators, fontSize = 12 },
) {
  await page.evaluate(({ nextLayout, nextRenderIndicators, nextFontSize }) =>
    globalThis.__diffEditorLifecycleControls.set_options(
      nextLayout,
      nextRenderIndicators,
      nextFontSize,
    ), {
    nextLayout: layout,
    nextRenderIndicators: renderIndicators,
    nextFontSize: fontSize,
  });
}

async function disposeDiffLifecycle(page) {
  await page.evaluate(() => {
    globalThis.__diffEditorLifecycleControls.dispose();
    globalThis.__diffEditorLifecycleControls.dispose_models();
  });
}

async function modifiedScrollTop(root) {
  return root.evaluate((node) => {
    const content = node.querySelector(
      '.moonbit-diff-editor-modified .lines-content',
    );
    if (!content) {
      throw new Error('missing modified diff lines content');
    }
    return Math.max(
      0,
      -(Number.parseFloat(getComputedStyle(content).top) || 0),
    );
  });
}

test('reveals raw mappings[0] when the first hunk starts on the cursor line', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  const modified = root.locator('.moonbit-diff-editor-modified');
  const scrollable = modified.locator(
    '.monaco-scrollable-element.editor-scrollable',
  );
  await setDiffLifecycleFixture(page, 'first-line');
  await waitForDiffLifecycleIdle(page);

  // Keep the model cursor at its initial line 1 while moving the viewport.
  // Cursor-relative `reveal_next_change` would skip that first hunk and land
  // on line 100; the VS Code API must always reveal raw mappings[0].
  await scrollable.hover();
  await page.mouse.wheel(0, 1400);
  await expect
    .poll(() => modifiedScrollTop(root))
    .toBeGreaterThan(500);
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.reveal_first_diff(),
  );

  await expect(
    modified.locator('.line-numbers.active-line-number'),
  ).toHaveText('1');
  await expect(
    modified.locator('.view-line').filter({
      hasText: 'new first hunk at line 1',
    }),
  ).toBeVisible();
  await expect
    .poll(() => modifiedScrollTop(root))
    .toBeLessThan(100);

  await disposeDiffLifecycle(page);
});

test('reveals the final raw mapping for backward multi-diff navigation', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  const modified = root.locator('.moonbit-diff-editor-modified');
  await setDiffLifecycleFixture(page, 'first-line');
  await waitForDiffLifecycleIdle(page);

  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.reveal_last_diff(),
  );

  await expect(
    modified.locator('.line-numbers.active-line-number'),
  ).toHaveText('100');
  await expect(
    modified.locator('.view-line').filter({
      hasText: 'new second hunk at line 100',
    }),
  ).toBeVisible();

  await disposeDiffLifecycle(page);
});

test('defers a one-shot first-diff reveal through computation and hidden layout', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  const host = page.locator('.diff-lifecycle-host');
  const modified = root.locator('.moonbit-diff-editor-modified');
  const scrollable = modified.locator(
    '.monaco-scrollable-element.editor-scrollable',
  );

  // Request the VS Code-style reveal while neither diff computation nor a
  // measurable two-pane layout is ready. Showing the host later must consume
  // the request for this exact model pair rather than dropping it.
  await host.evaluate((node) => {
    node.style.display = 'none';
  });
  await page.evaluate(() => {
    globalThis.__diffEditorLifecycleControls.set_fixture('late');
    globalThis.__diffEditorLifecycleControls.reveal_first_diff();
  });
  await expect
    .poll(() => page.evaluate(() =>
      globalThis.__diffEditorLifecycleControls.snapshot().diffUpToDate,
    ))
    .toBe(true);
  await host.evaluate((node) => {
    node.style.display = 'block';
  });
  await waitForDiffLifecycleIdle(page);

  await expect(
    modified.locator('.line-numbers.active-line-number'),
  ).toHaveText('121');
  await expect(
    modified.locator('.view-line').filter({ hasText: 'new first hunk' }),
  ).toBeVisible();
  const revealedScrollTop = await modifiedScrollTop(root);
  expect(revealedScrollTop).toBeGreaterThan(0);

  // The request is consumed once. A same-pair provider recomputation must not
  // pull a reviewer who has scrolled onward back to the first hunk.
  await scrollable.hover();
  await page.mouse.wheel(0, 1800);
  await expect
    .poll(() => modifiedScrollTop(root))
    .toBeGreaterThan(revealedScrollTop + 500);
  const reviewerScrollTop = await modifiedScrollTop(root);
  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_provider('core'),
  );
  await waitForDiffLifecycleIdle(page);
  const recomputedScrollTop = await modifiedScrollTop(root);
  expect(Math.abs(recomputedScrollTop - reviewerScrollTop)).toBeLessThanOrEqual(1);

  await disposeDiffLifecycle(page);
});

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
  const initialModifiedScrollHeight = Number(await modifiedOverview.getAttribute(
    'data-overview-ruler-scroll-height',
  ));
  // The original kernel itself stays unwrapped, but paired continuation
  // spacers make every wrapped deleted visual row consume equal geometry on
  // both sides.
  expect(originalScrollHeight).toBeGreaterThan(6000);
  expect(Math.abs(originalScrollHeight - initialModifiedScrollHeight)).toBeLessThanOrEqual(20);
  await page.locator('.diff-lifecycle-host').evaluate((node) => {
    node.style.width = '520px';
  });
  await expect
    .poll(async () => Number(await originalOverview.getAttribute(
        'data-overview-ruler-scroll-height',
      )))
    .toBeGreaterThan(originalScrollHeight);
  const resizedModifiedScrollHeight = Number(await modifiedOverview.getAttribute(
    'data-overview-ruler-scroll-height',
  ));
  expect(
    Math.abs(
      Number(await originalOverview.getAttribute('data-overview-ruler-scroll-height')) -
        resizedModifiedScrollHeight,
    ),
  ).toBeLessThanOrEqual(20);
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

test('inline original strip follows decimal digit bands and font metrics without a render loop', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  await setDiffLifecycleFixture(page, 'digits');
  await setDiffLifecycleOptions(page, {
    layout: 'inline',
    renderIndicators: true,
    fontSize: 12,
  });
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await waitForDiffLifecycleIdle(page);

  const readGeometry = () => root.evaluate((node) => {
    const original = node.querySelector('.moonbit-diff-editor-original');
    const modified = node.querySelector('.moonbit-diff-editor-modified');
    const originalRect = original.getBoundingClientRect();
    const modifiedRect = modified.getBoundingClientRect();
    return {
      attributeWidth: Number(node.getAttribute('data-inline-original-width')),
      originalWidth: originalRect.width,
      originalRight: originalRect.right,
      modifiedLeft: modifiedRect.left,
      overviewGenerations: Array.from(
        node.querySelectorAll('.diffOverviewRuler'),
        (ruler) => Number(ruler.getAttribute('data-overview-ruler-generation')),
      ),
    };
  });
  const expectJoinedGeometry = (geometry) => {
    expect(Math.abs(geometry.attributeWidth - geometry.originalWidth))
      .toBeLessThanOrEqual(1);
    expect(Math.abs(geometry.originalRight - geometry.modifiedLeft))
      .toBeLessThanOrEqual(1);
  };

  const nineLineGeometry = await readGeometry();
  expectJoinedGeometry(nineLineGeometry);
  await expect(
    root.locator('.moonbit-diff-editor-original .line-numbers').last(),
  ).toHaveText('9');

  await page.evaluate(() =>
    globalThis.__diffEditorLifecycleControls.set_digit_line_count(10),
  );
  await waitForDiffLifecycleIdle(page);
  await expect(
    root.locator('.moonbit-diff-editor-original .line-numbers').last(),
  ).toHaveText('10');
  const tenLineGeometry = await readGeometry();
  expectJoinedGeometry(tenLineGeometry);
  expect(tenLineGeometry.attributeWidth)
    .toBeGreaterThan(nineLineGeometry.attributeWidth);

  await setDiffLifecycleOptions(page, {
    layout: 'inline',
    renderIndicators: true,
    fontSize: 24,
  });
  await waitForDiffLifecycleIdle(page);
  const largeFontGeometry = await readGeometry();
  expectJoinedGeometry(largeFontGeometry);
  expect(largeFontGeometry.attributeWidth)
    .toBeGreaterThan(tenLineGeometry.attributeWidth);

  // The paired render barrier must reach a fixed generation after the strip
  // relayout. Sampling several later animation frames catches self-triggering
  // layout-info/strip feedback loops.
  await waitForAnimationFrames(page, 4);
  const stableGeometry = await readGeometry();
  expect(stableGeometry.attributeWidth).toBe(largeFontGeometry.attributeWidth);
  expect(stableGeometry.overviewGenerations)
    .toEqual(largeFontGeometry.overviewGenerations);
  await waitForDiffLifecycleIdle(page);

  await disposeDiffLifecycle(page);
});

test('renderIndicators removes only split and inline glyphs while retaining diff backgrounds', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  const originalPane = root.locator('.moonbit-diff-editor-original');
  const modifiedPane = root.locator('.moonbit-diff-editor-modified');
  const expectBackgrounds = async () => {
    await expect
      .poll(() => originalPane.locator(
        '.cmdr.diff-editor-gutter-delete',
      ).count())
      .toBeGreaterThan(0);
    await expect
      .poll(() => modifiedPane.locator(
        '.cmdr.diff-editor-gutter-insert',
      ).count())
      .toBeGreaterThan(0);
    await expect
      .poll(() => originalPane.locator('.diff-editor-line-delete').count())
      .toBeGreaterThan(0);
    await expect
      .poll(() => modifiedPane.locator('.diff-editor-line-insert').count())
      .toBeGreaterThan(0);
  };
  const expectLaneIndicators = async () => {
    await expect
      .poll(() => originalPane.locator(
        '.cldr.delete-sign.codicon-diff-remove',
      ).count())
      .toBeGreaterThan(0);
    await expect
      .poll(() => modifiedPane.locator(
        '.cldr.insert-sign.codicon-diff-insert',
      ).count())
      .toBeGreaterThan(0);
  };

  await setDiffLifecycleFixture(page, 'indicators');
  await setDiffLifecycleOptions(page, {
    layout: 'split',
    renderIndicators: true,
  });
  await expect(root).toHaveAttribute('data-render-mode', 'side-by-side');
  await waitForDiffLifecycleIdle(page);
  await expectBackgrounds();
  await expectLaneIndicators();

  await setDiffLifecycleOptions(page, {
    layout: 'split',
    renderIndicators: false,
  });
  await waitForDiffLifecycleIdle(page);
  await expect(root.locator('.cldr.delete-sign, .cldr.insert-sign')).toHaveCount(0);
  await expect(root.locator('.diff-editor-inline-delete-sign')).toHaveCount(0);
  await expectBackgrounds();

  await setDiffLifecycleOptions(page, {
    layout: 'inline',
    renderIndicators: true,
  });
  await expect(root).toHaveAttribute('data-render-mode', 'inline');
  await waitForDiffLifecycleIdle(page);
  await expectLaneIndicators();
  await expect
    .poll(() => root.locator('.diff-editor-inline-delete-sign').count())
    .toBeGreaterThan(0);
  await expectBackgrounds();

  await setDiffLifecycleOptions(page, {
    layout: 'inline',
    renderIndicators: false,
  });
  await waitForDiffLifecycleIdle(page);
  await expect(root.locator('.cldr.delete-sign, .cldr.insert-sign')).toHaveCount(0);
  await expect(root.locator('.diff-editor-inline-delete-sign')).toHaveCount(0);
  await expect(root.locator('.diff-editor-inline-deleted-block')).not.toHaveCount(0);
  await expectBackgrounds();

  await disposeDiffLifecycle(page);
});

test('identical pairs remain fully visible and decoration-free in split and inline layouts', async ({ page }) => {
  const root = await openDiffLifecycle(page);
  const status = root.locator('.moonbit-diff-editor-status');
  const diffArtifacts = root.locator([
    '.diff-editor-line-delete',
    '.diff-editor-line-insert',
    '.diff-editor-char-delete',
    '.diff-editor-char-insert',
    '.cmdr.diff-editor-gutter-delete',
    '.cmdr.diff-editor-gutter-insert',
    '.cldr.delete-sign',
    '.cldr.insert-sign',
    '.diff-editor-inline-deleted-block',
  ].join(','));
  const expectedLines = [1, 2, 3, 4, 5, 6, 7, 8];
  const expectIdenticalSurface = async (layout) => {
    await expect(root).toHaveAttribute('data-render-mode', layout);
    await waitForDiffLifecycleIdle(page);
    await expect(status).toBeHidden();
    await expect(root).not.toHaveAttribute('data-diff-failure');
    await expect(diffArtifacts).toHaveCount(0);
    const rulers = root.locator('.diffOverviewRuler');
    await expect(rulers).toHaveCount(2);
    await expect(rulers.nth(0)).toHaveAttribute(
      'data-overview-ruler-band-count',
      '0',
    );
    await expect(rulers.nth(1)).toHaveAttribute(
      'data-overview-ruler-band-count',
      '0',
    );
    const rendered = await root.evaluate((node) => {
      const paneEvidence = (selector) => {
        const pane = node.querySelector(selector);
        const rows = Array.from(
          pane.querySelectorAll(
            '.view-lines[data-view-part="view-lines"] > .view-line',
          ),
        );
        const lineNumbers = Array.from(
          pane.querySelectorAll('.margin-view-overlays .line-numbers'),
        );
        return {
          lines: Array.from(new Set(lineNumbers.map((lineNumber) =>
            Number(lineNumber.textContent),
          ))).sort((a, b) => a - b),
          rowCount: rows.length,
          text: rows.map((row) =>
            row.textContent.replaceAll('\u00a0', ' '),
          ).join('\n'),
        };
      };
      return {
        original: paneEvidence('.moonbit-diff-editor-original'),
        modified: paneEvidence('.moonbit-diff-editor-modified'),
      };
    });
    expect(rendered.original.lines).toEqual(expectedLines);
    expect(rendered.modified.lines).toEqual(expectedLines);
    expect(rendered.original.rowCount).toBe(expectedLines.length);
    expect(rendered.modified.rowCount).toBe(expectedLines.length);
    expect(rendered.original.text).toContain('identical 1');
    expect(rendered.original.text).toContain('identical 8');
    expect(rendered.modified.text).toContain('identical 1');
    expect(rendered.modified.text).toContain('identical 8');
  };

  await setDiffLifecycleFixture(page, 'identical');
  await setDiffLifecycleOptions(page, {
    layout: 'split',
    renderIndicators: true,
  });
  await expectIdenticalSurface('side-by-side');
  await setDiffLifecycleOptions(page, {
    layout: 'inline',
    renderIndicators: true,
  });
  await expectIdenticalSurface('inline');

  await disposeDiffLifecycle(page);
});
