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
| Tab / Shift + Tab | Move through the native edit, list, preview and action controls. |
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

Enable semantic search only after choosing a local folder and explicitly
downloading the optional model on the Search tile after accepting the linked
component licenses. Download, cancellation,
removal and status checks run on a cold worker. Missing or incompatible components
leave basic search available. Downloaded files are not reported as inference-ready
until the worker has passed its tokenizer, embedding and retrieval checks.
The optional component requires Windows 10 version 1903 or newer and a compatible
x64 runtime/CPU; basic search remains independent of it.

The pinned text-only EmbeddingGemma 2 ONNX model, tokenizer and Microsoft runtime
occupy about 370 MB after installation. A fresh download transfers about 398 MB,
including the runtime package; staging temporarily needs additional disk space.
Downloads use pinned sizes/hashes, and the runtime also requires a trusted
Microsoft signature before loading.

Semantic search considers up to 64 readable plain-text files discovered in the
selected folder, within the bounded local traversal. Hidden/system entries,
linked folders/files, network paths and offline files are excluded. UTF-8 and
BOM-marked UTF-16 are decoded. Each file contributes at most a 4 KB excerpt;
query/document inputs are right-truncated to 128 tokens including model prefixes
and special tokens. Matching text beyond those bounds is not examined. This is
not whole-document PDF/Office semantic indexing or an unlimited folder index.

The worker ranks four-document batches and publishes results progressively.
It caches document vectors and the most recent query vector while alive; a new
query still needs query inference. CPU inference is sequential, with one intra-op
and one inter-op thread and spinning disabled. The private child unloads after
60 seconds without a request; each request has a 30-second deadline. A newer
query or dismissal requests cancellation, and stale responses cannot update the
panel. The UI thread does not wait for model inference.

Controlled local checks measured about 7.7 seconds for a short cold request,
under 1 ms for an identical cached repeat, about 5.1 seconds for two 128-token
documents, and about 16.3 seconds for eight. Active-worker cancellation checks
completed in approximately 125–157 ms. These samples are not performance guarantees
for other hardware or storage. A full 64-file pass was not timed. First preparation
can be slow: roughly two minutes for 64 uncached files is an estimate from these
samples, not a measured folder pass or deadline. Basic results remain available
before semantic batches finish. Plain-text preview runs independently of model
work, so a preview request need not wait for semantic batches.

Local query/document text is exchanged with the owned child process. Runtime
telemetry is disabled before processing it. The model ranks text similarity; it
does not generate answers, execute instructions in documents or fetch web results.

## Interface and licenses

The panel uses native accessible Windows controls, Segoe UI and the original
Command mark. It is an opaque tool window with an OS-owned optional shadow,
system DPI handling and Windows high-contrast colors. It uses no Apple SDK,
desktop capture, blur renderer or idle animation. English source strings have
language-pack fallback, including the Russian pack; user file/app names are
preserved when owned labels are translated.

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
