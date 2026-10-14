# SwiftyToys Search

Search is a native Swift/Win32 panel for applications, files, calculations,
conversions, world clocks and explicit web searches. Basic search is enabled by
default; the optional semantic model is off and is not downloaded automatically.
It is an independent Windows implementation, not a port of Apple's Spotlight.

With the unmodified Mac keyboard preset, Cmd + Space opens this panel. The
effective routing replaces that preset's Windows Search destination only while
SwiftyToys Search is enabled. Custom rules and application scopes remain editable
on the Keyboard tile through the **Open search** action. The Search tile also
provides an Open Search button and the enable/disable setting.

| Operation | Behavior |
| --- | --- |
| Type a query | Results arrive progressively; newer queries invalidate older responses. |
| Up / Down | Select results while focus remains in the query or result list. |
| Enter / Open | Open the selected app, file, folder or action; a quick answer is copied. |
| Ctrl + Enter | Reveal a selected local file, folder or application item in Explorer. The effective Mac preset maps Cmd + Enter to this chord within SwiftyToys, preserving custom rules. |
| Cmd + C | With the Mac copy preset, copy a selected result path, action title or quick answer from the result list. In the query field, selected text keeps normal text-copy behavior; with no text selected, the selected quick answer is copied. |
| Space / Preview | Space in the result list requests a preview. Space in the query remains text input. |
| Tab / Shift + Tab | Move through visible native controls. Preview joins the tab order only when expanded. |
| Esc / Close | Dismiss the panel and invalidate pending work. Losing activation also dismisses it, except while an owned dialog is active. |

Plain-text previews support selection, scrolling and normal text copying. Other
files show metadata/path information and open in their registered application.
The **Search the web** result opens Google only when explicitly activated with
Enter/Open or a double click. Typing, ranking and previewing do not send the
query to Google.

The app-specific Cmd+Enter rule is added only when an existing rule does not own
that chord and the effective rule budget has room. Native Ctrl+Enter remains the
panel's reveal shortcut. Virtual Windows apps open AppsFolder; local items are
selected in their containing folder.

## Basic providers and quick answers

Application discovery uses Start-menu shortcuts and the Windows AppsFolder.
Application discovery and Windows Index queries run in separate, bounded child
jobs, so a slow provider cannot own the UI or input thread. Indexed filename and
content coverage depends on Windows Search configuration and installed filters.

The local filename fallback scans Desktop, Documents and Downloads. Each pass
has a 250 ms budget, a 2,048-item cap, depth four, and additional traversal bounds.
It skips hidden/system entries, reparse points and network roots. This fallback
is a bounded scan, not a complete replacement for the Windows Index. Results
from providers are combined by path; app/file opening requires explicit selection.

| Quick answer | Examples and scope |
| --- | --- |
| Calculator | `2+3*4`, `(2+3)*4`, `15% of 85`, `sqrt(144)`, `sin(pi/2)`. A bounded parser handles arithmetic, powers, percentages, constants and supported functions; trigonometric arguments use radians. |
| Units | `5 miles in km`, `32F in C`, `1 GiB MB`. Length, mass, volume, time, storage and temperature conversions work offline. Omitting the destination, as in `5 miles`, selects the converter's default target. |
| Currency | `120 USD RUB`, `$120`, `120€`. Symbols map to USD, EUR, GBP, JPY and RUB. An omitted target uses the Windows regional currency; if source and target match, the alternate is USD, or EUR when the home currency is USD. |
| World clock | `time in London`, `time Tokyo`, `time UTC`. Date/time is a snapshot taken when the query runs, using Windows time-zone and daylight-saving rules. |

Currency conversion uses the official
[Bank of Russia XML reference table](https://www.cbr.ru/development/SXML/).
The published date appears with the result. The cached table can remain available
offline; its date matters. These are reference rates, not live trading quotes.
Fetching the table sends no query text. The model never supplies currency rates.

Clock queries accept 20 case-insensitive English aliases plus UTC: London, Paris,
Berlin, Rome, Madrid, Moscow, Tokyo, Japan, New York, Los Angeles, San Francisco,
Chicago, Sydney, Singapore, Dubai, Delhi, Beijing, Hong Kong, Toronto and Seoul.
Japan is an alias for Tokyo. Other names are ordinary search queries.

## Optional local semantic search

The **Local library** indexes all available drive-letter fixed/removable local
disks by default. Choose additional folders, exclusions or folder-only scope on
the Search tile. Pause keeps saved results available; Rebuild removes only the
derived index. System folders, development caches, private agent/credential
folders, hidden/system files, network paths, reparse points and offline/cloud
placeholders are excluded. Unlettered mount points are not traversed.

The persistent Windows SQLite database stores file metadata, extracted fragments
and model-specific vectors. Changed files are requeued; completed directory
enumeration removes missing entries. Interrupted or inaccessible directories are
not treated as empty. Native change notifications queue affected directories;
overflow requests a rescan. No full disk traversal runs for each query.

| Content | Native handling |
| --- | --- |
| Text and source code | UTF-8/BOM UTF-16 fragments; bounded reads and line locators. |
| Office and filtered documents | Installed Windows IFilter handlers; coverage depends on available filters. |
| PDF | Windows PDF pages rendered with software WARP, then Windows OCR; one-based page locators. |
| Images | Windows Imaging Component, EXIF orientation and installed Windows OCR languages; optional image embeddings. |
| Audio | Media Foundation decodes 30-second mono segments; optional audio embeddings match recording content without a transcript. |
| Video | Media Foundation samples frames and audio with time locators; optional image/audio embeddings. |

Use `code:`, `pdf:`, `image:` (or `photo:`), `audio:` and `video:` before a query
to restrict library matches. Preview shows the matched text and page/line/time
locator; opening uses the registered application. Filename matches remain
available when content extraction or a codec is unavailable.

Indexing is paced: at most 128 metadata entries or about 40 ms per two-second
slice. Heavy extraction/inference waits for 30 seconds without user input,
10 seconds without Search activity, no foreground fullscreen window and no
Windows Battery Saver. It runs in a background-priority owned child, one content
slice or vector per step. User activity cancels heavy work while retaining
completed data. A native provider that stalls inside a call is stopped by the
supervisor's 60-second request deadline; cancellation does not kill other apps.
The child has a 1,536 MiB private-commit ceiling. Cold model loading also checks
available physical memory and commit: about 768 MiB for MiniLM, 1,280 MiB for
Gemma text, or 2,304 MiB for Gemma with media. Ongoing work requires 512 MiB of
headroom. Low-memory work waits and releases sessions; it does not mark files as
permanently failed. These safeguards do not make large models suitable for every
low-memory computer. Basic search remains independent of model preparation.

Limits are explicit: 200,000 files, 400,000 fragments and a 1 GiB database.
PDF batches contain four pages (up to 5,000 pages); audio/video continue in
bounded slices. Video samples three frames five seconds apart, with overlapping
30-second soundtrack windows; a missing codec is reported instead of inventing
content. Text reads stop at 1 MiB or 64 fragments of about 2,048 characters.
Text/Office/PDF/image files above 256 MiB are excluded from extraction; audio/video
files stream without that file-size cap. Decoded images are at most 2,048 pixels
on the longest edge, and video frames above four megapixels are excluded.
Coverage can be partial. Queries stream
top results with a 150 ms cooperative budget and report incomplete coverage;
large libraries may return partial matches. OS I/O can exceed a cooperative
budget, so disposable query children also have a hard deadline.

Enable semantic search and explicitly download a model after accepting its
component licenses. **EmbeddingGemma 2** remains recommended: text model,
tokenizer and signed Microsoft runtime occupy about 370 MB (roughly 398 MB fresh
transfer). Its optional image/audio encoders add about 535 MB. **MiniLM** is a
text-only alternative with about 90 MB of model weights; it shares the runtime.
Staging temporarily needs more disk space. Neither model is bundled in Setup.

The editable model picker searches public Hugging Face metadata only when
requested. Compatibility checks support the pinned Gemma conversion and standard
uncased six-layer BERT/MiniLM ONNX models with mean pooling, 384 dimensions,
30,522 vocabulary entries and Apache 2.0 licensing. Other architectures, gated
repositories, remote code, custom operators and external graph files are rejected
with an explanation. A selected revision and asset hashes are retained locally;
switching models invalidates vectors without discarding extracted text.

Document/media vectors are prepared in the background, then persisted. Typing a
semantic query requires only query inference and an index lookup. Indexed text
is split into lossless windows fitting the model's 128-token limit; the original
fragment remains available for exact strings spanning window boundaries. Gemma
vectors have 128 dimensions, MiniLM 384. Images/video use the upstream-supported
70-soft-token preprocessing budget; detailed text is handled separately by OCR.
CPU inference uses one intra-op/inter-op thread with spinning disabled. The query
child unloads after 60 seconds without requests and has a 30-second request
deadline. New input/dismissal cancels obsolete work; basic results arrive first.
Initial indexing and cold model loading can take time on older hardware. Source
freshness uses volume identity, size and modification time rather than hashing
every file. Rebuild if content was replaced while preserving those attributes.

Media preprocessing uses the upstream-supported 70-soft-token budget for both
images and video: at most 630 raw 16-by-16 RGB patches with three-by-three
pooling. A square image produces 576 real patches and 64 features. Padding,
position IDs and the encoder hashes are part of the media index namespace;
changing that pipeline invalidates its vectors. Audio uses 16 kHz mono PCM,
periodic Hann windows, a magnitude FFT and the upstream 128-band HTK mel
processor. No transcript or generated caption is substituted for raw media.

An owned synthetic fixture with the signed CPU runtime passed image/text color,
video-feature and 30-second tone/text retrieval checks inside a 1,536 MiB native
job. In that one run, image vectors took about 9–11 seconds, the full audio
window about 27 seconds, and peak private commit was about 638 MiB. Peak working
set reached about 1,157 MiB. These figures include model caches, differ from
UI idle memory, and are not a broad corpus or hardware performance guarantee.
Each production step handles one vector; the 60-second deadline can still skip
a difficult file. Native synthetic extraction checks also cover PCM audio,
timestamped video with row orientation, PDF software rendering and installed OCR.
Six non-square gradient/checkerboard comparisons against the upstream Pillow
processor matched patch layout, padding, masks and positions, with at most one
byte of pixel difference. This does not establish exact parity for arbitrary images.

Content, vectors and search queries stay local. Hugging Face receives model IDs
and download requests, never document paths or search text. Hashes and the
Microsoft runtime signature are checked before loading; runtime telemetry is
disabled. The model compares meaning and media content; it does not generate
answers, execute document instructions or supply currency rates.

## Interface and licenses

Search opens as a rounded, compact query bar. Up to six result rows expand below
it; longer lists scroll. Preview opens alongside results only when requested.
Native accessible edit/list controls retain selectable text, IME input, keyboard
navigation, Segoe UI, system DPI handling and the original Command mark.
While a nonempty query changes, the panel can grow to accommodate results but
does not shrink between replies. Clear or reopen it to return to the compact bar.
Progressive updates preserve the selected result and valid scroll position.
Pending results remain visible while providers work, with their actions disabled;
only a reply for the current query can make them actionable again.
Rows and action buttons use the OS buffered-paint API, committing their background
and text together. Failed or incomplete buffered drawing falls back to native
direct painting. The single-line query uses Windows' plain-text Rich Edit with
native input, caret, Unicode, selection and Undo. It does not accept rich text or
embedded objects, or automatically switch the keyboard layout or font size. The
hint disappears before IME composition and returns after an empty cancellation.

The surrounding surface uses Windows' own Acrylic material through
[OS XAML hosting](https://learn.microsoft.com/en-us/windows/uwp/xaml-islands/using-the-xaml-hosting-api),
initialized only when Search first opens. A narrow Acrylic frame surrounds one
continuous opaque content surface shared by input, results, preview and actions;
individual controls do not form disconnected bright rectangles over the glass.
The entire panel is not continuously transparent. Windows can replace
Acrylic with an opaque surface for high contrast, disabled transparency, power
saving or hardware limitations. SwiftyToys preserves those system choices and
uses native high-contrast colors. A material initialization failure leaves Search
usable with an opaque surface.

The background and native controls use Windows sibling clipping, so Acrylic
cannot draw into higher controls' visible regions. The OS framework remains
loaded after Search is hidden; the source closes before
its UI-thread manager at application exit. There is no separate WinUI/Windows App
SDK download, Apple SDK, desktop capture, application blur renderer or idle
animation. English strings have language-pack fallback, including the Russian
pack; user file/app names are preserved when owned labels are translated.

SwiftyToys' own implementation is [MIT](../LICENSE). Google's model and the
pinned ONNX conversion use [Apache 2.0](https://huggingface.co/google/embeddinggemma-2),
retained in [EmbeddingGemma2.txt](../Licenses/EmbeddingGemma2.txt). The downloaded
Microsoft binary has separate
[Windows ML Runtime terms](https://www.nuget.org/packages/Microsoft.Windows.AI.MachineLearning/2.4.89/License)
and [retained notices](../Licenses/WindowsML-THIRD-PARTY-NOTICES.txt); it is not
relicensed by the application's MIT license. The unmodified ONNX Runtime C API
declarations use [upstream MIT](https://github.com/microsoft/onnxruntime/blob/v1.27.1/LICENSE),
retained in [ONNXRuntimeHeaders.txt](../Licenses/ONNXRuntimeHeaders.txt).
See [third-party notices](../THIRD_PARTY_NOTICES.md) for the pinned sources.
