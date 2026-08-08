# DPI awareness and adaptive GUI layout

Field reports against the WinForms GUI showed blurry text on 4K (the process never declared DPI awareness, so Windows bitmap-stretched a 96-DPI UI) and cropped buttons at 150% DPI (fixed design-time control positions). `Enable-GuiDpiAwareness` now declares per-monitor DPI awareness before any WinForms assembly loads — required, since Windows latches DPI awareness on first use — and the Main Window was rebuilt on an auto-sizing layout so controls scale instead of clipping.

## Consequences

- `$form.MinimumSize` is computed after the auto-scale pass — computing it first would double-apply DPI scaling — then clamped to the monitor's `WorkingArea`, which can still shrink the window below its preferred size on an extreme DPI/small-desktop combination.
