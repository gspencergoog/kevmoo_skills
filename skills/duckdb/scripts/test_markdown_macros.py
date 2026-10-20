#!/usr/bin/env python3
"""Unit tests for skills/duckdb/scripts/markdown_macros.sql."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
MACROS_SQL = SCRIPTS_DIR / "markdown_macros.sql"


def _find_duckdb() -> str | None:
    """Finds the duckdb CLI executable on PATH or in ~/.local/bin."""
    found = shutil.which("duckdb")
    if found:
        return found
    candidate = Path.home() / ".local/bin/duckdb"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


DUCKDB_BIN = _find_duckdb()


@unittest.skipUnless(DUCKDB_BIN, "duckdb CLI binary not found")
class TestMarkdownMacros(unittest.TestCase):
    def setUp(self) -> None:
        self.test_dir = tempfile.mkdtemp()

    def tearDown(self) -> None:
        shutil.rmtree(self.test_dir)

    def _query(self, sql: str) -> list[dict[str, Any]]:
        """Executes a SQL query with markdown_macros.sql initialized and returns JSON rows."""
        res = subprocess.run(
            [
                str(DUCKDB_BIN),
                "-batch",
                "-dark-mode",
                "-json",
                "-init",
                str(MACROS_SQL),
                "-c",
                sql,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        out = res.stdout.strip()
        return json.loads(out) if out else []

    def test_section_hierarchy_breadcrumbs_and_subtree_spans(self) -> None:
        md_content = (
            "---\n"
            "name: sample-doc\n"
            "# frontmatter comment that must not become a heading\n"
            "---\n"
            "Preamble intro line.\n"
            "# Title H1\n"
            "Intro under H1.\n"
            "## First H2\n"
            "Body under first H2.\n"
            "### Nested H3 ###\n"
            "Deep body line 1.\n"
            "Deep body line 2.\n"
            "## Second H2\n"
            "Body under second H2 (H3 must reset in breadcrumb).\n"
        )
        doc_path = Path(self.test_dir) / "doc.md"
        doc_path.write_text(md_content, encoding="utf-8")

        sections = self._query(
            f"SELECT section_id, level, heading, breadcrumb, line_start, line_end, "
            f"subtree_line_end, own_lines, subtree_lines, own_code_blocks "
            f"FROM read_md_sections('{doc_path}');"
        )
        self.assertEqual(
            sections,
            [
                {
                    "section_id": 0,
                    "level": 0,
                    "heading": "(preamble)",
                    "breadcrumb": "(preamble)",
                    "line_start": 5,
                    "line_end": 5,
                    "subtree_line_end": 5,
                    "own_lines": 1,
                    "subtree_lines": 1,
                    "own_code_blocks": 0,
                },
                {
                    "section_id": 1,
                    "level": 1,
                    "heading": "Title H1",
                    "breadcrumb": "Title H1",
                    "line_start": 6,
                    "line_end": 7,
                    "subtree_line_end": 14,
                    "own_lines": 2,
                    "subtree_lines": 9,
                    "own_code_blocks": 0,
                },
                {
                    "section_id": 2,
                    "level": 2,
                    "heading": "First H2",
                    "breadcrumb": "Title H1 > First H2",
                    "line_start": 8,
                    "line_end": 9,
                    "subtree_line_end": 12,
                    "own_lines": 2,
                    "subtree_lines": 5,
                    "own_code_blocks": 0,
                },
                {
                    "section_id": 3,
                    "level": 3,
                    "heading": "Nested H3",
                    "breadcrumb": "Title H1 > First H2 > Nested H3",
                    "line_start": 10,
                    "line_end": 12,
                    "subtree_line_end": 12,
                    "own_lines": 3,
                    "subtree_lines": 3,
                    "own_code_blocks": 0,
                },
                {
                    "section_id": 4,
                    "level": 2,
                    "heading": "Second H2",
                    "breadcrumb": "Title H1 > Second H2",
                    "line_start": 13,
                    "line_end": 14,
                    "subtree_line_end": 14,
                    "own_lines": 2,
                    "subtree_lines": 2,
                    "own_code_blocks": 0,
                },
            ],
        )

    def test_nested_fences_and_code_block_extraction(self) -> None:
        md_content = (
            "# Guide\n"
            "```bash\n"
            "# shell comment inside 3-backtick block\n"
            "echo hello\n"
            "```\n"
            "## Templates\n"
            "````markdown\n"
            "# Fake Heading Inside 4-Backtick Block\n"
            "```python\n"
            "# nested python comment\n"
            "```\n"
            "````\n"
            "~~~sql\n"
            "# sql hash comment inside tilde block\n"
            "SELECT 1;\n"
            "~~~\n"
            "- List item with 4-space indented fence:\n"
            "    ```bash\n"
            "    # indented shell comment\n"
            "    echo list\n"
            "    ```\n"
        )
        doc_path = Path(self.test_dir) / "fences.md"
        doc_path.write_text(md_content, encoding="utf-8")

        sections = self._query(
            f"SELECT section_id, level, heading, own_code_blocks "
            f"FROM read_md_sections('{doc_path}');"
        )
        self.assertEqual(
            sections,
            [
                {
                    "section_id": 1,
                    "level": 1,
                    "heading": "Guide",
                    "own_code_blocks": 1,
                },
                {
                    "section_id": 2,
                    "level": 2,
                    "heading": "Templates",
                    "own_code_blocks": 3,
                },
            ],
        )

        blocks = self._query(
            f"SELECT block_id, section_id, section_heading, lang, "
            f"line_start, line_end, code_lines, code "
            f"FROM read_md_code_blocks('{doc_path}');"
        )
        self.assertEqual(
            blocks,
            [
                {
                    "block_id": 1,
                    "section_id": 1,
                    "section_heading": "Guide",
                    "lang": "bash",
                    "line_start": 2,
                    "line_end": 5,
                    "code_lines": 2,
                    "code": "# shell comment inside 3-backtick block\necho hello",
                },
                {
                    "block_id": 2,
                    "section_id": 2,
                    "section_heading": "Templates",
                    "lang": "markdown",
                    "line_start": 7,
                    "line_end": 12,
                    "code_lines": 4,
                    "code": (
                        "# Fake Heading Inside 4-Backtick Block\n"
                        "```python\n"
                        "# nested python comment\n"
                        "```"
                    ),
                },
                {
                    "block_id": 3,
                    "section_id": 2,
                    "section_heading": "Templates",
                    "lang": "sql",
                    "line_start": 13,
                    "line_end": 16,
                    "code_lines": 2,
                    "code": "# sql hash comment inside tilde block\nSELECT 1;",
                },
                {
                    "block_id": 4,
                    "section_id": 2,
                    "section_heading": "Templates",
                    "lang": "bash",
                    "line_start": 18,
                    "line_end": 21,
                    "code_lines": 2,
                    "code": "    # indented shell comment\n    echo list",
                },
            ],
        )

    def test_multi_file_glob_and_preamble_only_file(self) -> None:
        file_a = Path(self.test_dir) / "a.md"
        file_b = Path(self.test_dir) / "b.md"
        file_c = Path(self.test_dir) / "c_large.md"
        file_a.write_text("Just plain notes without any headings.\nLine two.\n", encoding="utf-8")
        file_b.write_text("# Doc B\nSome content.\n", encoding="utf-8")
        large_lines = [
            "---",
            "title: large-doc",
            "---",
            "# Large Doc",
        ]
        for idx in range(1, 25):
            large_lines.append(f"Intro line {idx}")
        large_lines.append("## Subheading At Line 29")
        for idx in range(1, 25):
            large_lines.append(f"Subheading line {idx}")
        file_c.write_text("\n".join(large_lines) + "\n", encoding="utf-8")

        glob_pat = str(Path(self.test_dir) / "*.md")
        sections = self._query(
            f"SELECT regexp_extract(file_path, '[^/]+$') AS name, "
            f"section_id, level, heading, line_start, line_end, subtree_line_end "
            f"FROM read_md_sections('{glob_pat}') "
            f"ORDER BY name, section_id;"
        )
        self.assertEqual(
            sections,
            [
                {
                    "name": "a.md",
                    "section_id": 0,
                    "level": 0,
                    "heading": "(preamble)",
                    "line_start": 1,
                    "line_end": 2,
                    "subtree_line_end": 2,
                },
                {
                    "name": "b.md",
                    "section_id": 1,
                    "level": 1,
                    "heading": "Doc B",
                    "line_start": 1,
                    "line_end": 2,
                    "subtree_line_end": 2,
                },
                {
                    "name": "c_large.md",
                    "section_id": 1,
                    "level": 1,
                    "heading": "Large Doc",
                    "line_start": 4,
                    "line_end": 28,
                    "subtree_line_end": 53,
                },
                {
                    "name": "c_large.md",
                    "section_id": 2,
                    "level": 2,
                    "heading": "Subheading At Line 29",
                    "line_start": 29,
                    "line_end": 53,
                    "subtree_line_end": 53,
                },
            ],
        )


if __name__ == "__main__":
    unittest.main()
