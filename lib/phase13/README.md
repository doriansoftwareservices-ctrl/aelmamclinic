## Phase 13

Localization foundation and hygiene gate.

This phase does not try to finish every screen translation. It establishes the
shared rules and the regression guard that the next cleanup phases depend on:

- stronger dynamic raw-string translation for recurring UI patterns,
- shared locale-aware runtime feedback,
- baseline allowlists for existing raw-Arabic hotspots,
- a hygiene check that fails when new untranslated UI text or new hard-coded
  directionality is introduced outside the current baseline.

Primary check:

```bash
./lib/phase13/check_localization_hygiene.sh
```
