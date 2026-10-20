-- Relational Markdown Indexing Macros for DuckDB
-- Load with: duckdb -batch -dark-mode -init skills/duckdb/scripts/markdown_macros.sql

-- Internal helper: Parse raw Markdown lines, strip YAML frontmatter, track
-- nested 3/4/5-backtick and tilde code fences, and classify ATX headings.
CREATE OR REPLACE MACRO _parse_markdown(md_glob) AS TABLE
WITH raw_lines AS (
  SELECT
    filename AS file_path,
    row_number() OVER (PARTITION BY filename) AS line_num,
    rtrim(COALESCE(line, ''), chr(13)) AS line
  FROM read_csv(
    md_glob,
    header=false,
    columns={'line': 'VARCHAR'},
    quote='',
    delim=chr(0),
    null_padding=true,
    filename=true
  )
),
frontmatter_state AS (
  SELECT
    file_path,
    line_num,
    line,
    FIRST_VALUE(line_num = 1 AND line = '---') OVER (
      PARTITION BY file_path ORDER BY line_num
    ) AS has_frontmatter,
    COUNT(*) FILTER (
      WHERE (line_num = 1 AND line = '---')
         OR (line_num > 1 AND line IN ('---', '...'))
    ) OVER (
      PARTITION BY file_path
      ORDER BY line_num
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS fm_delim_count
  FROM raw_lines
),
fm_filtered AS (
  SELECT
    file_path,
    line_num,
    line,
    (
      has_frontmatter
      AND (
        fm_delim_count = 1
        OR (fm_delim_count = 2 AND line IN ('---', '...'))
      )
    ) AS is_frontmatter
  FROM frontmatter_state
),
f5_marked AS (
  SELECT
    file_path,
    line_num,
    line,
    is_frontmatter,
    (
      NOT is_frontmatter
      AND regexp_matches(line, '^ {0,3}(`{5,}|~{5,})[^`~]*$')
    ) AS is_f5
  FROM fm_filtered
),
f5_state AS (
  SELECT
    *,
    (
      is_f5
      OR (
        COUNT(*) FILTER (WHERE is_f5) OVER (
          PARTITION BY file_path
          ORDER BY line_num
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) % 2 = 1
      )
    ) AS in_f5
  FROM f5_marked
),
f4_marked AS (
  SELECT
    *,
    (
      NOT is_frontmatter
      AND NOT in_f5
      AND regexp_matches(line, '^ {0,3}(`{4}|~{4})[^`~]*$')
    ) AS is_f4
  FROM f5_state
),
f4_state AS (
  SELECT
    *,
    (
      is_f4
      OR (
        COUNT(*) FILTER (WHERE is_f4) OVER (
          PARTITION BY file_path
          ORDER BY line_num
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) % 2 = 1
      )
    ) AS in_f4
  FROM f4_marked
),
t3_marked AS (
  SELECT
    *,
    (
      NOT is_frontmatter
      AND NOT in_f5
      AND NOT in_f4
      AND regexp_matches(line, '^ {0,3}~{3}[^~]*$')
    ) AS is_t3
  FROM f4_state
),
t3_state AS (
  SELECT
    *,
    (
      is_t3
      OR (
        COUNT(*) FILTER (WHERE is_t3) OVER (
          PARTITION BY file_path
          ORDER BY line_num
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) % 2 = 1
      )
    ) AS in_t3
  FROM t3_marked
),
b3_marked AS (
  SELECT
    *,
    (
      NOT is_frontmatter
      AND NOT in_f5
      AND NOT in_f4
      AND NOT in_t3
      AND regexp_matches(line, '^ {0,3}`{3}[^`]*$')
    ) AS is_b3
  FROM t3_state
),
fence_state AS (
  SELECT
    file_path,
    line_num,
    line,
    is_frontmatter,
    (is_f5 OR is_f4 OR is_t3 OR is_b3) AS is_fence_delim,
    (
      in_f5
      OR in_f4
      OR in_t3
      OR is_b3
      OR (
        COUNT(*) FILTER (WHERE is_b3) OVER (
          PARTITION BY file_path
          ORDER BY line_num
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) % 2 = 1
      )
    ) AS in_code_block,
    COUNT(*) FILTER (WHERE is_f5 OR is_f4 OR is_t3 OR is_b3) OVER (
      PARTITION BY file_path
      ORDER BY line_num
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS fence_delim_count
  FROM b3_marked
),
classified AS (
  SELECT
    file_path,
    line_num,
    line,
    is_frontmatter,
    is_fence_delim,
    in_code_block,
    CASE
      WHEN in_code_block THEN (fence_delim_count + 1) // 2
      ELSE NULL
    END AS code_block_id,
    CASE
      WHEN is_fence_delim AND (fence_delim_count % 2 = 1) THEN
        trim(regexp_extract(line, '^ {0,3}(?:`{3,}|~{3,})[ \t]*([^`~\s]*)', 1))
      ELSE NULL
    END AS fence_lang,
    (
      NOT is_frontmatter
      AND NOT in_code_block
      AND regexp_matches(line, '^#{1,6}[ \t]+\S')
    ) AS is_heading,
    CASE
      WHEN NOT is_frontmatter AND NOT in_code_block AND regexp_matches(line, '^#{1,6}[ \t]+\S')
      THEN strlen(regexp_extract(line, '^(#{1,6})[ \t]+', 1))
      ELSE NULL
    END AS heading_level,
    CASE
      WHEN NOT is_frontmatter AND NOT in_code_block AND regexp_matches(line, '^#{1,6}[ \t]+\S')
      THEN trim(regexp_replace(regexp_extract(line, '^#{1,6}[ \t]+(.*)$', 1), '[ \t]+#+[ \t]*$', ''))
      ELSE NULL
    END AS heading_text
  FROM fence_state
)
SELECT
  file_path,
  line_num,
  line,
  is_frontmatter,
  is_fence_delim,
  in_code_block,
  code_block_id,
  fence_lang,
  is_heading,
  heading_level,
  heading_text,
  COUNT(*) FILTER (WHERE is_heading) OVER (
    PARTITION BY file_path
    ORDER BY line_num
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS section_id
FROM classified;

-- 1. Index Markdown sections with hierarchical breadcrumbs and subtree line spans
CREATE OR REPLACE MACRO read_md_sections(md_glob) AS TABLE
WITH parsed AS (
  SELECT * FROM _parse_markdown(md_glob)
),
section_agg AS (
  SELECT
    file_path,
    section_id,
    COALESCE(MAX(heading_level), 0) AS level,
    COALESCE(MAX(heading_text), '(preamble)') AS heading,
    MIN(line_num) AS line_start,
    MAX(line_num) AS line_end,
    (MAX(line_num) - MIN(line_num) + 1) AS own_lines,
    COUNT(DISTINCT code_block_id) AS own_code_blocks,
    string_agg(line, chr(10) ORDER BY line_num) AS content
  FROM parsed
  WHERE NOT is_frontmatter
  GROUP BY file_path, section_id
),
file_bounds AS (
  SELECT
    file_path,
    MAX(line_num) AS file_max_line
  FROM parsed
  GROUP BY file_path
),
hierarchy AS (
  SELECT
    s.file_path,
    s.section_id,
    s.level,
    s.heading,
    s.line_start,
    s.line_end,
    s.own_lines,
    s.own_code_blocks,
    s.content,
    NULLIF(LAST_VALUE(CASE WHEN s.level = 1 THEN s.heading END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h1,
    NULLIF(LAST_VALUE(CASE WHEN s.level BETWEEN 1 AND 2 THEN CASE WHEN s.level = 2 THEN s.heading ELSE '' END END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h2,
    NULLIF(LAST_VALUE(CASE WHEN s.level BETWEEN 1 AND 3 THEN CASE WHEN s.level = 3 THEN s.heading ELSE '' END END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h3,
    NULLIF(LAST_VALUE(CASE WHEN s.level BETWEEN 1 AND 4 THEN CASE WHEN s.level = 4 THEN s.heading ELSE '' END END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h4,
    NULLIF(LAST_VALUE(CASE WHEN s.level BETWEEN 1 AND 5 THEN CASE WHEN s.level = 5 THEN s.heading ELSE '' END END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h5,
    NULLIF(LAST_VALUE(CASE WHEN s.level BETWEEN 1 AND 6 THEN CASE WHEN s.level = 6 THEN s.heading ELSE '' END END IGNORE NULLS) OVER (
      PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), '') AS h6,
    COALESCE(
      CASE s.level
        WHEN 0 THEN s.line_end
        WHEN 1 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 1 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
        WHEN 2 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 2 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
        WHEN 3 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 3 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
        WHEN 4 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 4 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
        WHEN 5 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 5 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
        WHEN 6 THEN MIN(CASE WHEN s.level BETWEEN 1 AND 6 THEN s.line_start END) OVER (PARTITION BY s.file_path ORDER BY s.section_id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) - 1
      END,
      b.file_max_line
    ) AS subtree_line_end
  FROM section_agg s
  JOIN file_bounds b ON s.file_path = b.file_path
)
SELECT
  file_path,
  section_id,
  level,
  heading,
  CASE
    WHEN level = 0 THEN '(preamble)'
    ELSE concat_ws(' > ', h1, h2, h3, h4, h5, h6)
  END AS breadcrumb,
  line_start,
  line_end,
  subtree_line_end,
  own_lines,
  (subtree_line_end - line_start + 1) AS subtree_lines,
  own_code_blocks,
  content
FROM hierarchy
ORDER BY file_path, section_id;

-- 2. Extract fenced code blocks with enclosing section metadata and line spans
CREATE OR REPLACE MACRO read_md_code_blocks(md_glob) AS TABLE
WITH parsed AS (
  SELECT * FROM _parse_markdown(md_glob)
),
section_titles AS (
  SELECT
    file_path,
    section_id,
    COALESCE(MAX(heading_text), '(preamble)') AS section_heading
  FROM parsed
  WHERE NOT is_frontmatter
  GROUP BY file_path, section_id
)
SELECT
  p.file_path,
  p.code_block_id AS block_id,
  FIRST(p.section_id ORDER BY p.line_num) AS section_id,
  FIRST(COALESCE(s.section_heading, '(preamble)') ORDER BY p.line_num) AS section_heading,
  COALESCE(MAX(p.fence_lang), '') AS lang,
  MIN(p.line_num) AS line_start,
  MAX(p.line_num) AS line_end,
  COUNT(*) FILTER (WHERE NOT p.is_fence_delim) AS code_lines,
  COALESCE(
    string_agg(p.line, chr(10) ORDER BY p.line_num) FILTER (WHERE NOT p.is_fence_delim),
    ''
  ) AS code
FROM parsed p
LEFT JOIN section_titles s
  ON p.file_path = s.file_path
 AND p.section_id = s.section_id
WHERE p.in_code_block
GROUP BY p.file_path, p.code_block_id
ORDER BY p.file_path, p.code_block_id;
