#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

ARABIC_LITERAL_RE = re.compile(
    r"'[^'\n]*[\u0600-\u06FF][^'\n]*'|\"[^\"\n]*[\u0600-\u06FF][^\"\n]*\""
)
BLOCK_COMMENT_RE = re.compile(r'/\*.*?\*/', re.DOTALL)
LINE_COMMENT_RE = re.compile(r'//.*?$' , re.MULTILINE)
SAFE_PREFIXES = (
    'context.trRaw(',
    'context.tr(',
    'LocalizedText(',
    '_trChat(',
    '_trChatService(',
    '_tr(',
    '_snack(',
    'RawStringLocalizer.translate(',
    'RawStringLocalizer.translateWithCurrentLocale(',
    'pw.Text(',
    '_PdfUtils.header(',
    '_PdfUtils.simpleTable(',
    '_Section(',
    '_SectionTitle(',
    '_PlanHeaderModern(',
    '_PlanPricingCard(',
    '_CardSectionLabel(',
    '_FeatureRow(',
    '_KpiItem(',
    '_GrowthCard(',
    '_RevenueCardData(',
    '_FilterAndExportBar(',
    '_ChartsSection(',
    '_TopList(',
    '_statChip(',
    '_metaPill(',
    '_tabLabels',
    '_paidBaseFeatures',
    '_freeFeatures',
    '_proExtraFeatures',
    '_employeesPolicyForPlan(',
    '_planDisplayName(',
    'TSectionHeader(',
    'TDateButton(',
    'TOutlinedButton(',
    'TPrimaryButton(',
    'NeuButton.primary(',
    'NeuButton.flat(',
)
SAFE_SUFFIXES = (
    'child: LocalizedText(',
    'child: const LocalizedText(',
    'title: LocalizedText(',
    'title: const LocalizedText(',
)
DEFAULT_EXCLUDES = {
    'lib/l10n/raw_string_localizer.dart',
}


def strip_comments(text: str) -> str:
    text = BLOCK_COMMENT_RE.sub(lambda m: ' ' * (m.end() - m.start()), text)
    text = LINE_COMMENT_RE.sub(lambda m: ' ' * (m.end() - m.start()), text)
    return text


def is_ignored(text: str, start: int) -> bool:
    prefix = text[max(0, start - 600) : start]
    suffix = text[start : start + 240]
    return any(token in prefix for token in SAFE_PREFIXES) or any(
        token in suffix for token in SAFE_SUFFIXES
    )


def scan_file(path: Path) -> tuple[int, list[tuple[int, str]]]:
    text = path.read_text(encoding='utf-8')
    text = strip_comments(text)
    hits: list[tuple[int, str]] = []
    for match in ARABIC_LITERAL_RE.finditer(text):
        if is_ignored(text, match.start()):
            continue
        line = text.count('\n', 0, match.start()) + 1
        snippet = match.group(0)
        hits.append((line, snippet[:120]))
    return len(hits), hits


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Heuristic audit for untranslated Arabic literals in Dart files.',
    )
    parser.add_argument('root', nargs='?', default='lib', help='Directory to scan')
    parser.add_argument('--limit', type=int, default=40, help='Max files to print')
    parser.add_argument(
        '--include-localizer',
        action='store_true',
        help='Include the raw string localizer source file in results.',
    )
    parser.add_argument(
        '--show-lines',
        action='store_true',
        help='Print matched line numbers for each reported file',
    )
    args = parser.parse_args()

    root = Path(args.root)
    if not root.exists():
        raise SystemExit(f'Path not found: {root}')

    per_file: dict[Path, list[tuple[int, str]]] = {}
    total_hits = 0
    for path in sorted(root.rglob('*.dart')):
        if (not args.include_localizer and path.as_posix() in DEFAULT_EXCLUDES):
            continue
        count, hits = scan_file(path)
        if count == 0:
            continue
        per_file[path] = hits
        total_hits += count

    print(f'root: {root}')
    print(f'files_with_hits: {len(per_file)}')
    print(f'raw_literal_hits: {total_hits}')
    print()

    ranked = sorted(
        per_file.items(),
        key=lambda item: (len(item[1]), str(item[0])),
        reverse=True,
    )
    for path, hits in ranked[: args.limit]:
        print(f'{len(hits):4} {path}')
        if args.show_lines:
            for line, snippet in hits[:20]:
                print(f'     L{line}: {snippet}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
