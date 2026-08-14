import { expect, test } from '../support/test.js';

const editorSelector = '.cursor-input-host > .monaco-editor.readonly-editor';
const cursorFixtureText = [
  'alpha',
  '  beta gamma delta',
  'wrap alpha beta gamma delta epsilon zeta eta theta iota kappa lambda',
  '',
  '  ; punctuation value',
  'line six',
  'line seven',
  'line eight',
  'line nine',
  'line ten',
  'line eleven',
  'omega',
].join('\n');

async function settle(page) {
  await page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
}

async function mountCursorFixture(page) {
  await page.goto('/browser-tests/component.html?cursorInput=1');
  await page.waitForFunction(() => Boolean(globalThis.__cursorInputControls));
  await expect(page.locator(editorSelector)).toContainText('alpha');
  await page.evaluate(() => globalThis.__cursorInputControls.focus());
  await settle(page);
  await expect
    .poll(() =>
      page.evaluate(
        () => document.activeElement === globalThis.__cursorInputControls.root,
      ),
    )
    .toBe(true);
}

async function state(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.state());
}

async function events(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.events());
}

async function keys(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.keys());
}

async function propagation(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.propagation());
}

async function focusEvents(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.focus_events());
}

async function pointers(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.pointers());
}

async function copies(page) {
  return page.evaluate(() => globalThis.__cursorInputControls.copies());
}

async function copiedPayload(page) {
  return page.evaluate(() =>
    globalThis.__cursorInputControls.copied_payload(),
  );
}

async function clear(page) {
  await page.evaluate(() => globalThis.__cursorInputControls.clear());
}

async function setPosition(page, line, column) {
  await page.evaluate(
    ([nextLine, nextColumn]) => {
      globalThis.__cursorInputControls.set_position(nextLine, nextColumn);
      globalThis.__cursorInputControls.focus();
    },
    [line, column],
  );
  await settle(page);
  await clear(page);
}

function expectOneCursorPair(log, cursorState, source, reason, previousState) {
  expect(log.map((event) => event.type)).toEqual(['position', 'selection']);
  const [position, selection] = log;
  expect(position).toMatchObject({
    line: cursorState.position.line,
    column: cursorState.position.column,
    secondaryCount: 0,
    source,
    reason,
    committedLine: cursorState.position.line,
    committedColumn: cursorState.position.column,
  });
  expect(selection).toMatchObject({
    anchorLine: cursorState.selection.anchorLine,
    anchorColumn: cursorState.selection.anchorColumn,
    activeLine: cursorState.selection.activeLine,
    activeColumn: cursorState.selection.activeColumn,
    secondaryCount: 0,
    source,
    reason,
    committedAnchorLine: cursorState.selection.anchorLine,
    committedAnchorColumn: cursorState.selection.anchorColumn,
    committedActiveLine: cursorState.selection.activeLine,
    committedActiveColumn: cursorState.selection.activeColumn,
  });
  if (previousState) {
    expect(selection).toMatchObject({
      oldSelectionCount: 1,
      oldAnchorLine: previousState.selection.anchorLine,
      oldAnchorColumn: previousState.selection.anchorColumn,
      oldActiveLine: previousState.selection.activeLine,
      oldActiveColumn: previousState.selection.activeColumn,
    });
  }
}

function expectAdjacentCursorPairs(log) {
  expect(log.length % 2).toBe(0);
  for (let index = 0; index < log.length; index += 2) {
    expect(log[index].type).toBe('position');
    expect(log[index + 1].type).toBe('selection');
  }
}

async function expectFocused(page) {
  await expect
    .poll(() =>
      page.evaluate(
        () => document.activeElement === globalThis.__cursorInputControls.root,
      ),
    )
    .toBe(true);
  await expect(page.locator(editorSelector)).toHaveClass(/focused/);
}

async function press(page, key) {
  await page.keyboard.press(key);
  await settle(page);
  const keyLog = await keys(page);
  expect(keyLog.length).toBeGreaterThan(0);
  return keyLog.at(-1);
}

async function copySelection(page) {
  await page.keyboard.press('ControlOrMeta+C');
  return page.evaluate(() => globalThis.__readonlyEditorCopiedText || '');
}

async function clickBurst(page, point, count) {
  await page.mouse.move(point.x, point.y);
  for (let clickCount = 1; clickCount <= count; clickCount += 1) {
    await page.mouse.down({ clickCount });
    await page.mouse.up({ clickCount });
  }
  await settle(page);
}

async function textPoint(page, text, occurrence = 0) {
  const point = await page.locator(`${editorSelector} .view-lines`).evaluate(
    (root, { needle, wantedOccurrence }) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let seen = 0;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        let from = 0;
        while (from <= node.textContent.length) {
          const index = node.textContent.indexOf(needle, from);
          if (index < 0) break;
          if (seen === wantedOccurrence) {
            const range = document.createRange();
            range.setStart(node, index);
            range.setEnd(node, index + needle.length);
            const rect = range.getBoundingClientRect();
            return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
          }
          seen += 1;
          from = index + needle.length;
        }
      }
      return null;
    },
    { needle: text, wantedOccurrence: occurrence },
  );
  expect(point).not.toBeNull();
  return point;
}

test('all 16 primary real keys prevent defaults retain focus and converge events', async ({
  page,
}) => {
  await mountCursorFixture(page);
  const cases = [
    { chord: 'ArrowLeft', line: 6, column: 3 },
    { chord: 'Shift+ArrowLeft', line: 6, column: 3 },
    { chord: 'ArrowRight', line: 6, column: 3 },
    { chord: 'Shift+ArrowRight', line: 6, column: 3 },
    { chord: 'ArrowUp', line: 6, column: 3 },
    { chord: 'Shift+ArrowUp', line: 6, column: 3 },
    { chord: 'ArrowDown', line: 6, column: 3 },
    { chord: 'Shift+ArrowDown', line: 6, column: 3 },
    { chord: 'Home', line: 2, column: 10 },
    { chord: 'Shift+Home', line: 2, column: 10 },
    { chord: 'End', line: 2, column: 10 },
    { chord: 'Shift+End', line: 2, column: 10 },
    { chord: 'PageUp', line: 8, column: 3 },
    { chord: 'Shift+PageUp', line: 8, column: 3 },
    { chord: 'PageDown', line: 4, column: 3 },
    { chord: 'Shift+PageDown', line: 4, column: 3 },
  ];
  for (const entry of cases) {
    await setPosition(page, entry.line, entry.column);
    const before = await state(page);
    const key = await press(page, entry.chord);
    expect(key).toMatchObject({ defaultPrevented: true, activeIsRoot: true });
    const current = await state(page);
    expect(current.selection).not.toEqual(before.selection);
    expectOneCursorPair(
      await events(page),
      current,
      'keyboard',
      'Explicit',
      before,
    );
    // The editor intentionally stops a handled key at its root. The sibling
    // root observer still saw defaultPrevented above; the document bubble
    // observer must not see it.
    expect(
      (await propagation(page)).filter((event) => event.key === key.key),
    ).toEqual([]);
    expect(
      (await focusEvents(page)).filter((event) => event.type === 'focusout'),
    ).toEqual([]);
    await expectFocused(page);
  }
});

test('model copy stays editor-owned while ViewZone selection and keys stay native', async ({
  page,
}) => {
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await mountCursorFixture(page);

  // The ordinary model path still writes both clipboard representations and
  // prevents the browser's default copy.
  await page.evaluate(() => {
    const controls = globalThis.__cursorInputControls;
    controls.set_selection(1, 1, 1, 6);
    controls.focus();
    controls.reset_copy();
  });
  await page.keyboard.press('ControlOrMeta+C');
  expect(await copiedPayload(page)).toMatchObject({ plain: 'alpha' });
  expect((await copiedPayload(page)).html).toContain('alpha');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
    'alpha',
  );
  expect((await copies(page)).at(-1)).toMatchObject({
    defaultPrevented: true,
    nativeSelection: '',
  });

  // An empty model selection keeps the browser default, as before.
  await page.evaluate(() => {
    const controls = globalThis.__cursorInputControls;
    controls.set_position(1, 1);
    controls.focus();
    controls.clear_native_selection();
    controls.reset_copy();
  });
  await page.keyboard.press('ControlOrMeta+C');
  expect(await copiedPayload(page)).toEqual({ plain: '', html: '' });
  expect((await copies(page)).at(-1)).toMatchObject({
    defaultPrevented: false,
    nativeSelection: '',
  });

  // Even with a non-empty model selection, either endpoint inside the
  // caller-owned ViewZone leaves its real native DOM selection untouched.
  await page.evaluate(() => globalThis.__cursorInputControls.show_zone());
  await settle(page);
  await expect(
    page.locator(`${editorSelector} .cursor-input-view-zone`),
  ).toBeVisible();
  const zoneSelection = await page.evaluate(() => {
    const controls = globalThis.__cursorInputControls;
    controls.set_selection(1, 1, 1, 6);
    const selected = controls.select_zone_text();
    controls.reset_copy();
    return selected;
  });
  expect(zoneSelection).toEqual({
    text: 'caller-owned zone text',
    activeIsRoot: true,
  });
  await page.keyboard.press('ControlOrMeta+C');
  expect(await copiedPayload(page)).toEqual({ plain: '', html: '' });
  expect((await copies(page)).at(-1)).toMatchObject({
    defaultPrevented: false,
    nativeSelection: 'caller-owned zone text',
  });
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
    'caller-owned zone text',
  );

  // Event origin is an independent gate: a copy dispatched from a focusable
  // ViewZone descendant remains native even with no DOM text selection.
  expect(
    await page.evaluate(() => {
      const controls = globalThis.__cursorInputControls;
      controls.clear_native_selection();
      controls.reset_copy();
      return controls.focus_zone_link();
    }),
  ).toBe(true);
  await page.keyboard.press('ControlOrMeta+C');
  expect(await copiedPayload(page)).toEqual({ plain: '', html: '' });
  expect((await copies(page)).at(-1)).toMatchObject({
    defaultPrevented: false,
    nativeSelection: '',
    targetClass: 'cursor-input-view-zone-link',
  });

  // Focused caller DOM owns every bubbled key. Navigation cannot mutate the
  // model cursor; Enter/Space preserve the link's native keyboard path.
  const beforeKeys = await state(page);
  const activationBefore = await page.evaluate(
    () => globalThis.__cursorInputControls.zone_link_activations(),
  );
  for (const key of ['ArrowLeft', 'Home', 'PageDown', 'Enter', 'Space']) {
    await page.evaluate(() => {
      const controls = globalThis.__cursorInputControls;
      controls.clear();
      controls.focus_zone_link();
    });
    await page.keyboard.press(key);
    await settle(page);
    expect((await keys(page)).at(-1)).toMatchObject({
      key: key === 'Space' ? ' ' : key,
      defaultPrevented: false,
      activeIsRoot: false,
    });
    expect(await state(page)).toEqual(beforeKeys);
    expect(await events(page)).toEqual([]);
    expect((await propagation(page)).at(-1)).toMatchObject({
      key: key === 'Space' ? ' ' : key,
      defaultPrevented: false,
    });
  }
  expect(
    await page.evaluate(
      () => globalThis.__cursorInputControls.zone_link_activations(),
    ),
  ).toBe(activationBefore + 1);
});

test('real single click and drag keep visible selection and mouse event pairs coherent', async ({
  page,
}) => {
  await mountCursorFixture(page);
  const beta = await textPoint(page, 'beta');
  const delta = await textPoint(page, 'delta');

  await clear(page);
  await page.mouse.click(beta.x, beta.y);
  await settle(page);
  let current = await state(page);
  expectOneCursorPair(await events(page), current, 'mouse', 'Explicit');
  await expectFocused(page);

  await clear(page);
  await page.mouse.click(beta.x, beta.y);
  await settle(page);
  expect(await events(page)).toEqual([]);

  await setPosition(page, 1, 1);
  await page.mouse.move(beta.x, beta.y);
  await page.mouse.down();
  await page.mouse.move(delta.x, delta.y, { steps: 8 });
  await page.mouse.up();
  await settle(page);
  const log = await events(page);
  expectAdjacentCursorPairs(log);
  for (const event of log) {
    expect(event).toMatchObject({ source: 'mouse', reason: 'Explicit' });
  }
  current = await state(page);
  expect(current.selection.anchorLine).toBe(2);
  expect(current.selection.activeLine).toBe(2);
  expect(current.selection.activeColumn).toBeGreaterThan(current.selection.anchorColumn);
  await expect.poll(() => page.locator(`${editorSelector} .selected-text`).count()).toBeGreaterThan(0);
  await expectFocused(page);
});

test('real multi-click and gutter gestures preserve kinds and SelectAll source metadata', async ({
  page,
}) => {
  await mountCursorFixture(page);
  const beta = await textPoint(page, 'beta');

  await clear(page);
  await page.mouse.dblclick(beta.x, beta.y);
  await settle(page);
  let current = await state(page);
  expect(current.selection).toEqual({
    anchorLine: 2,
    anchorColumn: 3,
    activeLine: 2,
    activeColumn: 7,
  });
  let log = await events(page);
  expectAdjacentCursorPairs(log);
  expect(log.at(-1)).toMatchObject({ source: 'mouse', reason: 'Explicit' });

  await page.evaluate(() => globalThis.__cursorInputControls.resize(200));
  await settle(page);
  const punctuation = await textPoint(page, ';');
  await clear(page);
  await page.mouse.dblclick(punctuation.x, punctuation.y);
  await settle(page);
  current = await state(page);
  expect(current.selection.anchorLine).toBe(5);
  expect(current.selection.activeLine).toBe(5);
  expect(
    Math.abs(current.selection.activeColumn - current.selection.anchorColumn),
  ).toBe(1);

  const lineBox = await page
    .locator(`${editorSelector} .view-line[data-line="2"]`)
    .boundingBox();
  const gutterBox = await page.locator(`${editorSelector} .margin-view-overlays .line-numbers`).nth(1).boundingBox();
  expect(lineBox).not.toBeNull();
  expect(gutterBox).not.toBeNull();
  await clear(page);
  await page.mouse.click(gutterBox.x + gutterBox.width / 2, lineBox.y + lineBox.height / 2);
  await settle(page);
  log = await events(page);
  expectAdjacentCursorPairs(log);
  expect(log.at(-1)).toMatchObject({ source: 'mouse', reason: 'Explicit' });
  current = await state(page);
  expect(current.selection.anchorLine).toBe(2);
  expect(current.selection.activeLine).toBe(3);

  await clear(page);
  await clickBurst(page, beta, 4);
  current = await state(page);
  expect(current.selection).toEqual({
    anchorLine: 1,
    anchorColumn: 1,
    activeLine: 12,
    activeColumn: 6,
  });
  log = await events(page);
  expectAdjacentCursorPairs(log);
  expect(log.at(-2)).toMatchObject({ source: 'keyboard', reason: 'Explicit' });
  expect(log.at(-1)).toMatchObject({ source: 'keyboard', reason: 'Explicit' });
  expect(await copySelection(page)).toBe(cursorFixtureText);

  // Drive an exact count > 4 from a non-SelectAll state. MouseDownState still
  // owns the previous four-click burst, so detail=5 is accepted at the same
  // logical position and must route through the >=4 SelectAll branch.
  await setPosition(page, 2, 4);
  await page.mouse.click(beta.x, beta.y, { clickCount: 5 });
  await settle(page);
  expect((await pointers(page)).at(-2)).toMatchObject({
    type: 'mousedown',
    detail: 5,
  });
  current = await state(page);
  expect(current.selection).toEqual({
    anchorLine: 1,
    anchorColumn: 1,
    activeLine: 12,
    activeColumn: 6,
  });
  log = await events(page);
  expectAdjacentCursorPairs(log);
  expectOneCursorPair(log.slice(-2), current, 'keyboard', 'Explicit');
  expect(log.length).toBeGreaterThanOrEqual(2);
  await expect.poll(() => page.locator(`${editorSelector} .selected-text`).count()).toBeGreaterThan(0);
  await expectFocused(page);
});
