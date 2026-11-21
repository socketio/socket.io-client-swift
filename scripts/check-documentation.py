#!/usr/bin/env python3
"""Check current documentation's local links and headings without network access.

Supports the inline/reference Markdown links, ATX headings and HTML href/src/id
attributes used in this repository. This is not a general CommonMark renderer.
Historical report bodies are intentionally excluded; their indexes are checked.
"""
import argparse
import html
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
import unicodedata
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = '/kaeferfreund/socket.io-client-swift/'
HISTORICAL = {
    'Documentation/ProtocolParityReview.md',
    'Documentation/JevAckFollowup-2026-09-19.md',
    'Documentation/JevParityReview-2026-09-19.md',
}


def prose(text):
    """Remove comments and fenced code while preserving source line numbers."""
    text = re.sub(r'<!--.*?-->', lambda m: '\n' * m[0].count('\n'), text, flags=re.S)
    lines, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            lines.append('\n' if line.endswith('\n') else '')
        elif marker:
            fence = marker[1]
            lines.append('\n' if line.endswith('\n') else '')
        else:
            lines.append(line)
    return ''.join(lines)


def mask_inline_code(text):
    """Mask matched backtick spans, preserving offsets and source line numbers."""
    return re.sub(
        r'(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)',
        lambda match: re.sub(r'[^\n]', ' ', match[0]),
        text,
        flags=re.S,
    )


class HTMLReferences(HTMLParser):
    """Collect actual HTML link targets and anchors, ignoring valueless attributes."""
    def __init__(self):
        """Initialize empty link and anchor collections with HTML entity decoding."""
        super().__init__(convert_charrefs=True)
        self.links = []
        self.anchors = set()

    def handle_starttag(self, tag, attrs):
        """Record href/src targets with line numbers and explicit id/name anchors."""
        for key, value in attrs:
            if value is None:
                continue
            if key in ('href', 'src'):
                self.links.append((self.getpos()[0], value))
            if key == 'id' or (tag == 'a' and key == 'name'):
                self.anchors.add(value)


def anchors(text):
    """Return explicit HTML anchors and deduplicated GitHub-style heading slugs."""
    text = prose(text)
    parser = HTMLReferences()
    parser.feed(mask_inline_code(text))
    result, used = set(parser.anchors), set()
    for match in re.finditer(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$', text, re.M):
        title = re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', match[1])
        title = html.unescape(re.sub(r'<[^>]*>', '', title)).replace('`', '').replace('*', '').lower()
        slug = ''.join(c for c in title if c in '-_' or unicodedata.category(c)[0] not in 'PS')
        slug = re.sub(r'\s', '-', slug)
        candidate, suffix = slug, 0
        while candidate in used:
            suffix += 1
            candidate = f'{slug}-{suffix}'
        used.add(candidate)
        result.add(candidate)
    return result


def links(text):
    """Yield source line and destination pairs, flagging undefined references."""
    text = prose(text)
    # Inline code is prose for heading slugs, but not for link extraction.
    text = mask_inline_code(text)
    parser = HTMLReferences()
    parser.feed(text)
    yield from parser.links
    # Each repeated alternative consumes a distinct character or parenthesized segment.
    # A nested + here makes unterminated destinations backtrack exponentially.
    destination = r'(<[^>\n]+>|(?:[^\s()]|\([^()]*\))+)(?:\s+[\"\'][^\n]*?[\"\'])?'
    for match in re.finditer(r'\]\(' + destination + r'\)', text):
        yield text.count('\n', 0, match.start()) + 1, match[1].strip('<>')
    definitions = {}
    for match in re.finditer(r'^ {0,3}\[([^]]+)\]:\s*' + destination, text, re.M):
        definitions[' '.join(match[1].lower().split())] = match[2].strip('<>')
        yield text.count('\n', 0, match.start()) + 1, match[2].strip('<>')
    for match in re.finditer(r'\[([^]\n]+)\]\[([^]\n]*)\]', text):
        key = ' '.join((match[2] or match[1]).lower().split())
        if key not in definitions:
            yield text.count('\n', 0, match.start()) + 1, 'missing-reference:' + key


def current_documents(root):
    """Select current documentation and indexes while retaining historical exclusions."""
    paths = set(root.glob('*.md')) - {root / 'CHANGELOG.md'}
    paths.update(root.glob('Documentation/*.md'))
    for directory in ('Documentation/Guides', 'Documentation/Development', '.github'):
        paths.update((root / directory).rglob('*.md'))
    for name in ('Documentation/Archive/README.md', 'Documentation/ReviewEvidence/README.md',
                 'scripts/README.md', 'docs/index.html'):
        if (root / name).is_file():
            paths.add(root / name)
    return sorted(p for p in paths if p.relative_to(root).as_posix() not in HISTORICAL)


def validate(root=ROOT):
    """Return diagnostics for missing paths, missing anchors and repository escapes."""
    root = Path(root).resolve()
    errors, cache = [], {}
    documents = current_documents(root)
    if not documents:
        return ['No current documentation found']
    for source in documents:
        for line, target in links(source.read_text(encoding='utf-8')):
            label = f'{source.relative_to(root)}:{line}: {target}'
            if target.startswith('missing-reference:'):
                errors.append(label + ' (undefined Markdown reference)')
                continue
            url = urlsplit(html.unescape(target))
            base = source.parent
            if url.scheme or url.netloc:
                # Current-branch links in the Pages landing page are checked
                # against this checkout; pinned historical/remote links are not.
                prefix = REPOSITORY + 'blob/master/'
                tree_prefix = REPOSITORY + 'tree/master/'
                if url.netloc == 'github.com' and url.path.startswith((prefix, tree_prefix)):
                    path = url.path[len(prefix if url.path.startswith(prefix) else tree_prefix):]
                    base = root
                else:
                    continue
            else:
                path = url.path
            if not path:
                resolved = source.resolve()
            else:
                decoded = unquote(path)
                resolved = (root / decoded.lstrip('/') if decoded.startswith('/') else base / decoded).resolve()
            if not resolved.is_relative_to(root):
                errors.append(label + ' (outside repository)')
            elif not resolved.exists():
                errors.append(label + ' (missing path)')
            elif url.fragment and resolved.is_file() and resolved.suffix.lower() in ('.md', '.html'):
                if resolved not in cache:
                    cache[resolved] = anchors(resolved.read_text(encoding='utf-8'))
                if unquote(url.fragment) not in cache[resolved]:
                    errors.append(label + ' (missing anchor)')
    return errors


def main():
    """Run the offline validator and return a nonzero status for invalid links."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    errors = validate(args.root)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'PASS: local links and anchors in {len(current_documents(args.root.resolve()))} current documents; remote URLs and historical bodies not checked.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
