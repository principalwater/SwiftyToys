# Swift Ember

Swift Ember uses an original three-feather mark and coral/orange tones to express
lightness and momentum. It is inspired by Swift and the PowerToys tool model;
the mark is independent artwork, not an Apple or Microsoft logo.

The same icon appears in Explorer, the notification area, window caption and
settings header. Eight embedded resolutions (16–256 px) provide transparent edges
without a runtime image library. The SVG is the editable source; regenerate the
ICO after changing its geometry. Icon handles have explicit native ownership and
are replaced after the window has received its new DPI-sized handles.

The Windows 10 interface uses quiet solid cards, rounded controls, status pills,
clear typography and a warm accent for primary actions. This draws on Apple's
light material hierarchy; it does not implement Apple's Liquid Glass API. There
is no desktop capture, blur frame loop or idle animation. Painting runs only in
response to window events. High contrast uses system colors; native controls
retain accessible names, Tab focus and Overview/Esc navigation.

The caption and fonts follow Windows DPI. Physical mixed-monitor DPI and screen
reader acceptance are separate from native layout checks. The interface currently
uses the selected light appearance; a complete dark theme remains future work.
