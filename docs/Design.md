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

## Search interaction

Search opens as a compact, resizable tool window. The native query edit leads the
hierarchy; the accessible result list sits beside a selectable, scrollable preview.
Open, Preview, Copy and Close remain native controls with Tab focus. The panel
uses Segoe UI, the Command mark and the Swift Ember palette; its solid surface
and optional Windows shadow use no captured desktop or blur animation.

Up/Down selects a result without moving focus out of the query. Enter activates
the selection; quick answers copy their value. Cmd+C keeps normal copying for
selected query text, and copies a selected quick answer when the query has no
selection. Space previews from the result list while remaining ordinary input in
the query. Ctrl+Enter reveals a local selected item; the Mac preset routes Cmd+Enter
to this chord only within SwiftyToys. IME composition retains its Enter/arrow keys.
Esc and activation loss dismiss the panel and invalidate work; an owned dialog
preserves the panel until the dialog closes.

Results and previews arrive as bounded values on the UI thread. Query generation
and selected result identity reject stale responses; coalesced delivery avoids
one queued message per update. Basic results appear before optional semantic
work, with progressive batch status. Model acquisition and explicit web opening
are separate user actions. The web row sends a query only after activation.

Drawing and native accessibility expose the same translated owned labels and
actual result names. File/app titles, amounts and dates remain data. System
high-contrast colors, visible native focus and DPI-sized fonts/icons take priority
over the decorative palette. Rendering responds to window events without an
application animation timer. Provider/model coverage and limits are recorded in
[Search](Search.md).
