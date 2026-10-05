# Language packs

English is the source language, default UI language and fallback for missing strings.
About → Display language applies a selection immediately and saves it for next launch.
Keyboard action names, shortcuts, application names, paths and diagnostics remain
canonical data; translations cannot change what a shortcut executes.

1. Copy `Languages/en-US.json` to a BCP-47-style filename such as `fr-FR.json`.
2. Set `_locale` to `fr-FR` and `_name` to the language's display name.
3. Translate JSON values. Keep English keys and numbered placeholders such as `{0}`.
4. Save UTF-8 without a BOM. Put the file in `Languages` beside the executable or
   `%LOCALAPPDATA%\SwiftyToys\Languages`, then reopen About to discover it.

Each pack is a flat JSON object with string values, under 32 KiB. Duplicate keys,
invalid locale/path characters, NULs, missing/extra numbered placeholders and invalid
UTF-8 are rejected. Invalid external files are ignored and English remains available.
At most 64 files are inspected in each directory. User-directory packs take precedence
over bundled translations. No code, HTML, scripts, URLs or plugin binaries execute
from a language pack. A rebuild is not needed for a new translation.

The loader reuses the existing bounded state JSON codec and native file APIs instead
of adding a Foundation/XML/YAML runtime. The separation of source resources from
translated values follows the approach used by
[PowerToys](https://github.com/microsoft/PowerToys/blob/main/doc/devdocs/development/localization.md)
and [Windhawk](https://github.com/ramensoftware/windhawk-translate).
The native storage self-check validates pack parsing, fallback and placeholders;
the UI self-check exercises every discovered language's controls and navigation.
