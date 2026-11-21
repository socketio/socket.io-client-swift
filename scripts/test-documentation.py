#!/usr/bin/env python3
"""Regression checks for the offline documentation validator."""
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

CHECKER_PATH = Path(__file__).with_name('check-documentation.py')
CHECKER = runpy.run_path(str(CHECKER_PATH))


class DocumentationTests(unittest.TestCase):
    """Exercise documentation validation against isolated temporary repositories."""
    def setUp(self):
        """Create a minimal repository fixture and register automatic cleanup."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write('README.md', '# Start\n')

    def write(self, name, content):
        """Write a UTF-8 fixture file, creating its parent directories as needed."""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        return path

    def check(self):
        """Return validation diagnostics for the current temporary repository."""
        return CHECKER['validate'](self.root)

    def test_valid_relative_file_and_heading(self):
        """Accept relative file links and existing heading fragments."""
        self.write('README.md', '[Guide](Documentation/Guide.md#example)\n')
        self.write('Documentation/Guide.md', '# Example\n[Back](../README.md)\n')
        self.assertEqual(self.check(), [])

    def test_missing_file_fails(self):
        """Report a missing local destination instead of accepting the link."""
        self.write('README.md', '[Missing](missing.md)')
        self.assertIn('missing path', self.check()[0])

    def test_missing_fragment_fails(self):
        """Reject a fragment absent from the target document."""
        self.write('README.md', '# Start\n[Missing](#absent)')
        self.assertIn('missing anchor', self.check()[0])

    def test_duplicate_and_unicode_headings(self):
        """Preserve Unicode and inline-code words while numbering duplicate slugs."""
        self.write('README.md', '# Café & `Swift`\n## Same\n## Same\n[One](#café--swift) [Two](#same-1)')
        self.assertEqual(self.check(), [])

    def test_existing_numbered_heading_does_not_collide(self):
        """Skip occupied numeric suffixes when generating duplicate heading anchors."""
        self.assertEqual(CHECKER['anchors']('# A\n# A-1\n# A\n'), {'a', 'a-1', 'a-2'})

    def test_fenced_and_inline_code_and_comments_are_ignored(self):
        """Exclude example links inside code fences, inline code and HTML comments."""
        self.write('README.md', '# Start\n```md\n[No](absent.md)\n```\n~~~\n[No](absent.md)\n~~~\n`[No](absent.md)`\n<!-- [No](absent.md) -->')
        self.assertEqual(self.check(), [])

    def test_space_and_parentheses_in_paths(self):
        """Accept escaped spaces, angle-bracket paths and parenthesized segments."""
        self.write('README.md', '[One](a%20b.md) [Two](file(1).md) [Three](<a b.md>)')
        self.write('a b.md', '# A')
        self.write('file(1).md', '# B')
        self.assertEqual(self.check(), [])

    def test_reference_definition_and_undefined_reference(self):
        """Resolve defined references and report an undefined reference label."""
        self.write('README.md', '# Start\n[Here][guide]\n[guide]: #start\n')
        self.assertEqual(self.check(), [])
        self.write('README.md', '[Here][missing]')
        self.assertIn('undefined Markdown reference', self.check()[0])

    def test_reference_destination_is_checked(self):
        """Validate a reference definition destination as a local file path."""
        self.write('README.md', '[Here][guide]\n[guide]: absent.md\n')
        self.assertIn('missing path', self.check()[0])

    def test_html_links_and_ids(self):
        """Accept actual HTML anchors and reject missing image sources."""
        self.write('README.md', '<a id="target"></a>\n<a href="#target">Here</a>')
        self.assertEqual(self.check(), [])
        self.write('README.md', '<img src="missing.png">')
        self.assertIn('missing path', self.check()[0])

    def test_remote_links_are_not_fetched(self):
        """Leave external URL availability outside the offline validation scope."""
        self.write('README.md', '[Remote](https://example.invalid/missing.md#no)')
        self.assertEqual(self.check(), [])

    def test_pages_current_repo_link_is_local(self):
        """Check Pages links to current master files against the local checkout."""
        self.write('docs/index.html', '<a href="https://github.com/kaeferfreund/socket.io-client-swift/blob/master/missing.md">No</a>')
        self.assertIn('missing path', self.check()[0])

    def test_pinned_history_is_not_mistaken_for_current(self):
        """Do not resolve immutable historical GitHub URLs against current files."""
        self.write('README.md', '[Old](https://github.com/kaeferfreund/socket.io-client-swift/blob/7adf66498a086bdb7b5e75d032c9560b0b7aec64/missing.md)')
        self.assertEqual(self.check(), [])

    def test_path_escape_is_rejected(self):
        """Reject local destinations that resolve outside the repository root."""
        self.write('README.md', '[Escape](../outside.md)')
        self.assertIn('outside repository', self.check()[0])

    def test_historical_bodies_excluded_but_indexes_checked(self):
        """Keep historical reports excluded while checking their current indexes."""
        for name in ('CHANGELOG.md', 'Documentation/ProtocolParityReview.md',
                     'Documentation/ReviewEvidence/Old.md', 'Documentation/Archive/UsageDocs/FAQ.md'):
            self.write(name, '[Historical](absent.md)')
        self.assertEqual(self.check(), [])
        self.write('Documentation/Archive/README.md', '[Broken](absent.md)')
        self.assertIn('missing path', self.check()[0])

    def test_source_line_number_survives_code_fences(self):
        """Report original source line numbers after masking fenced examples."""
        self.write('README.md', '```\nignored\n```\n[Broken](missing.md)\n')
        self.assertTrue(self.check()[0].startswith('README.md:4:'))

    def test_link_with_title(self):
        """Accept an inline destination followed by an optional quoted title."""
        self.write('README.md', '# Start\n[Here](#start "A title")')
        self.assertEqual(self.check(), [])


    def test_inline_code_html_cannot_define_an_anchor(self):
        """Reject links whose only matching id or name appears in a code span."""
        for attribute in ('id', 'name'):
            with self.subTest(attribute=attribute):
                self.write('README.md', f'# Start\n`<a {attribute}="target"></a>`\n[Broken](#target)\n')
                self.assertEqual(self.check(), ['README.md:3: #target (missing anchor)'])

    def test_real_html_anchors_survive_inline_code_masking(self):
        """Keep genuine anchors usable when code examples appear beside them."""
        self.write('README.md', '`<a id="fake">` <a id="real"></a> <a name="named"></a>\n'
                   '[Real](#real) [Named](#named)\n')
        self.assertEqual(self.check(), [])
        self.assertNotIn('fake', CHECKER['anchors'](self.root.joinpath('README.md').read_text()))

    def test_heading_inline_code_keeps_its_slug(self):
        """Retain inline-code words in slugs without collecting their literal HTML."""
        self.write('README.md', '# Install `SocketIO`\n'
                   '[Heading](#install-socketio)\n`<a id="fake">`\n')
        self.assertEqual(CHECKER['anchors'](self.root.joinpath('README.md').read_text()),
                         {'install-socketio'})
        self.assertEqual(self.check(), [])

    def test_multiline_inline_code_preserves_line_numbers(self):
        """Mask multiline code-span anchors and links without shifting diagnostics."""
        self.write('README.md', '# Start\nExample `<a id="fake">\n'
                   '[Ignored](missing.md)\n</a>`\n'
                   '[Broken](#fake)\n[Missing](missing.md)\n')
        self.assertEqual(self.check(), ['README.md:5: #fake (missing anchor)',
                                        'README.md:6: missing.md (missing path)'])

    def test_inline_code_requires_matching_backtick_runs(self):
        """Allow inner backticks without treating their surrounding HTML as markup."""
        self.write('README.md', '# Start\nExample ``literal ` tick <a id="fake">``\n'
                   '[Broken](#fake)\n')
        self.assertEqual(self.check(), ['README.md:3: #fake (missing anchor)'])
        self.assertEqual(CHECKER['anchors']('Example ``literal ` <a id="real"></a>'), {'real'})

    def test_unterminated_destinations_finish_within_timeout(self):
        """Bound malformed-link checks in a subprocess so a regex regression cannot hang CI."""
        probe = """
import runpy
import sys
checker = runpy.run_path(sys.argv[1])
payload = 'a' * 100_000
for malformed in ('[Broken](' + payload,
                  '[Broken](file(1)' + payload,
                  '[Broken](' + payload + ' "unfinished title'):
    assert list(checker['links'](malformed)) == []
print('malformed destinations completed')
"""
        result = subprocess.run([sys.executable, '-c', probe, str(CHECKER_PATH)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('malformed destinations completed', result.stdout)

    def test_parenthesized_destinations_with_titles_and_references(self):
        """Preserve destination, reference and title extraction after the regex fix."""
        self.write('file(1).md', '# Example\n')
        self.write('a b.md', '# Space\n')
        self.write('README.md', '[One](file(1).md#example "double title")\n'
                   "[Two](file(1).md#example 'single title')\n"
                   '[Three](<a b.md> "space title")\n'
                   '[Four][guide]\n[guide]: file(1).md#example "reference title"\n')
        self.assertEqual(self.check(), [])
        destinations = [target for _, target in CHECKER['links'](self.root.joinpath('README.md').read_text())]
        self.assertEqual(destinations, ['file(1).md#example', 'file(1).md#example',
                                        'a b.md', 'file(1).md#example'])


if __name__ == '__main__':
    unittest.main()
