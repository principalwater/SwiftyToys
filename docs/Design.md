# Swift Ember

Swift Ember uses an original Command-style mark and coral/orange tones.
Four rounded loops express familiar Mac keyboard habits; the warm palette draws
on Swift, and feature tiles draw on PowerToys. The mark uses custom paths, not
outlined system fonts, and is independent artwork.

The same icon appears in Explorer, the visible notification area, its hidden-icon
overflow, window caption and settings header. Windows uses one registered icon
for both tray locations. Eight embedded resolutions (16–256 px) provide transparent edges
without a runtime image library. The SVG is the editable source; regenerate the
ICO after changing its geometry. Icon handles have explicit native ownership and
are replaced after the window has received its new DPI-sized handles.

Installation also includes a fixed `resources/SwiftyToys.ico`. Before first launch,
the installer sets this icon and the stable `SwiftyToys.SwiftyToys` AppUserModelID
on the Start-menu shortcut; the process declares the same identity. Shell receives
targeted item notifications after the files are written. No global icon-cache
purge, Explorer restart, pin changes or versioned icon scheme is used.

The Windows 10 interface uses quiet solid cards, rounded controls, status pills,
clear typography and a warm accent for primary actions. This draws on Apple's
light material hierarchy; it does not implement Apple's Liquid Glass API. There
is no desktop capture, blur frame loop or idle animation. Painting runs only in
response to window events. High contrast uses system colors; native controls
retain accessible names, Tab focus and Overview/Esc navigation.

The caption and fonts follow Windows DPI. Physical mixed-monitor DPI and screen
reader acceptance are separate from native layout checks. The interface currently
uses the selected light appearance; a complete dark theme remains future work.
