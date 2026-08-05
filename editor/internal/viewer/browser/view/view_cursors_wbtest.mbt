///|
test "cursors_layer_class ports _getClassName's reachable arms" {
  // viewCursors.ts:286-340 with readonly constants: line style, solid blink.
  inspect(
    cursors_layer_class(false),
    content="cursors-layer cursor-line-style cursor-solid",
  )
  // :288-290 — a non-empty selection adds `has-selection`.
  inspect(
    cursors_layer_class(true),
    content="cursors-layer has-selection cursor-line-style cursor-solid",
  )
}

///|
test "compute_screen_aware_size snaps to the device pixel grid" {
  // dom.ts computeScreenAwareSize: max(1, floor(dpr*css)) / dpr.
  inspect(compute_screen_aware_size(1.0, 2.0), content="2")
  inspect(compute_screen_aware_size(2.0, 2.0), content="2")
  // floor(1.25*2)=2 → 2/1.25 = 1.6 (a sub-CSS-pixel-snapped width).
  inspect(compute_screen_aware_size(1.25, 2.0), content="1.6")
  // The max(1, …) clamp: half a CSS pixel still paints one device pixel.
  inspect(compute_screen_aware_size(1.0, 0.5), content="1")
}
