// Shared live-preview fixture strings (WI #160 owns this file, ruling D17).
//
// Every live-preview WI's byte-exact tests sweep these: row split/join
// round-trips (A1), span plain text (B1, B4), open-without-edit saves nothing
// (C1). Keys are stable names; add entries, never change existing bytes.
// Required shapes: CRLF, tabs, trailing spaces, no final newline, empty
// segment, nested lists, numbered runs reaching 10, fences holding list-like
// lines, quotes, transclusion tokens, frontmatter, emoji (surrogate pairs).

/// Fixture segment texts by name.
const Map<String, String> markdownFixtures = {
  'empty': '',
  'single line no newline': 'Just one line',
  'single newline': '\n',
  'paragraphs': 'First paragraph line one\nline two\n\nSecond paragraph.\n',
  'headings':
      '# Title\n## Section\n### Sub\n#### Four\n##### Five\n###### Six\n'
      '####### seven is text\n#tag is text\n#\n',
  'crlf': '# Plan\r\n\r\n- one\r\n- two\r\n  - nested\r\nafter list\r\n',
  'crlf no final newline': 'line a\r\n- item\r\n1. first\r\n> quote',
  'tabs': '\t- tab bullet\n\t\t- two tabs\n\tplain after tab\n- top\n',
  'trailing spaces': 'para with trailing   \n- item trailing  \n  \n> q  \n',
  'no final newline': 'Morning pages\n- buy milk\n- walk',
  'nested lists':
      '- a\n  - b\n    - c\n  - d\n- e\n    - f deeper\n  - g between\n',
  'mixed markers': '* star\n+ plus\n- dash\n-no space\n- \n-\n',
  'numbered to ten':
      '1. one\n2. two\n3. three\n4. four\n5. five\n6. six\n7. seven\n'
      '8. eight\n9. nine\n10. ten\n',
  'numbered runs':
      '8. a\n9. b\n10. c\n\n1. new run\n2. b\n   - nested bullet\n3. c\n'
      '1) not an item\n007. as written\n',
  'tasks':
      '- [ ] open\n- [x] done\n* [X] done upper\n+ [ ]\n- [ ]x not a task\n'
      '1. [ ] numbered not a task\n  - [ ] nested task\n',
  'fence with list-like lines':
      'Before\n```dart\n- not a list\n1. not numbered\n# not a heading\n'
      '> not a quote\n---\n\n```\nAfter\n',
  'indented fence': 'para\n  ```\n  code\n\t```\n- after\n',
  'unclosed fence': 'Intro\n```\n- inside\n\nmore\n',
  'tilde fence and indented code':
      '~~~\n- tilde is not a fence\n~~~\n\n    indented code is plain\n',
  'quotes':
      '> quoted line\n>\n> > nested is text\n> - list in quote\n>no space\n',
  'rules': '---\n***\n___\n-----\n-*-\n--\nText\n---\n',
  'transclusions':
      'See ![[2026-09-05#^b7k2m9]] here\n- item ![[2026-09-05#^b7k2m9..^c3d4e5]]\n'
      '[[Player Loop|the loop]] and [[Sleep~about]]\n',
  'frontmatter':
      '---\ntitle: Plan\ntags:\n  - a\n# not heading\n---\n# Body\n- item\n',
  'frontmatter crlf': '---\r\nk: v\r\n  ---  \r\nbody\r\n',
  'frontmatter unclosed': '---\nk: v\n- item\n',
  'emoji':
      '😀 start\n- 🎲 dice item\n- [ ] 👍🏽 task\n> 🧪 quote\n1. 🔟 ten\n'
      'end 🏳️‍🌈',
  'emoji no newline': '- 😀😀',
  'daily note':
      '## 2026-10-26\n\nMorning pages, slept well.\n\n- [x] ship A1\n'
      '- [ ] review [[Player Loop]]\n  - sub point with `code`\n\n'
      '> **Note**: keep it short\n\n```\nlet a = 1;\n```\n\nEvening.\n',
  'only whitespace': '   \n\t\n',
  'lone carriage return': 'a\rb\n- c\r',
};
