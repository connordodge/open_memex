# Long-note benchmark

`long_note_benchmark_test.dart` is the profile-mode benchmark for Spec #122
(long-note performance, Requirements 3-11). It runs the real note editor on
the shared synthetic notes N1-N5 (`test/support/long_note_fixtures.dart`) and
reports frame, event and open times, judged against the Spec's limits.

`flutter test` (the gate) never runs it: it sits outside `test/`, and
`test/perf/long_note_benchmark_wiring_test.dart` checks that. No CI step runs
it either. The matrix, the statistics, the targets and the report are plain
Dart in `benchmark_core.dart`, tested by
`test/perf/long_note_benchmark_core_test.dart`.

## Run it

It needs a profile build on macOS, with the app window in the **foreground**
for the whole run. An unattended or hidden window draws no frames, and every
number is then meaningless. If `flutter drive` does not bring the built app
to the front, open it yourself:

```
open build/macos/Build/Products/Profile/Open\ Memex.app
```

Then, from `app/`:

```
flutter drive --profile -d macos \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/long_note_benchmark_test.dart
```

The full matrix (72 cases and 4 scenarios) takes a long time. Narrow it with
`BENCH_CASES`, a comma-separated list of case id prefixes:

```
flutter drive --profile -d macos \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/long_note_benchmark_test.dart \
  --dart-define=BENCH_CASES=n1-plain-outline-closed,source-n1
```

A case id is the note, the variant, the Outline state and the spelling
state: `n1-plain-outline-open-spell-on`. The notes are `n1` (plain, 3,000
lines), `n2` (the same as bullets), `n5` (550 long lines), `n3` and `n4` (N1
and N2 at 12,000 lines). The variants are `plain`, `misspelled`,
`misspelled-heavy` (N1, N2, N5 only) and `decorated`. The scenarios outside
the matrix are `source-n1` (Source mode), `daily-n1-capture-gutter` (a daily
note with the capture gutter), `paste-n1-empty-note` and
`reload-n1-outside-edit`. A prefix that matches nothing stops the run with an
error that names it. An empty `BENCH_CASES` runs everything.

The benchmark never touches a real vault: it pumps the app over in-memory
fakes (a fake vault database, spelling service and CLI), a temp directory and
a stubbed clipboard (and a text-only pasteboard reader, so a paste never
reads the machine's pasteboard). The app runs on the real clock, so the spell
check's re-checks after a scroll pause or an edit and the save debounce fire
as they do in the app, and the binding draws every frame the framework asks
for (a fling runs on the engine's vsync). With spelling on, the benchmark
first walks down the page, pausing a screen at a time, so the rows the scroll
passes already carry their squiggles.

## Output

The driver writes everything the benchmark reports to
`build/long_note_benchmark_results.json` (under `app/`). It holds:

- `cases`: per case id, per metric, `{count, median, p90, max}` in
  milliseconds.
- `verdicts`: one row per judged (case, metric): the Requirement, the limit,
  the observed max and the verdict.
- `markdown`: the same verdicts as a table, ready for a PR body.
- `failures`: a phase that threw, with its case id, the first line of the
  error and the top three stack frames (repo-relative paths, never a home
  path). The run goes on; the metrics of that phase read `INCOMPLETE` in
  `verdicts`.

### Metrics

Frame metrics come from the engine's frame timings: build is the UI thread's
time for a frame, raster the raster thread's; only the frames of the measured
phase count, not the idle frames around it. Event metrics are per event: the
time the input handler runs plus the UI-thread time of the frames the event
caused (waiting for the next vsync is not counted). Each event metric has 24
events per case.

| Metric | What it measures |
| --- | --- |
| `fling-build`, `fling-raster` | frames while a touch fling of the page runs out |
| `jump30-build`, `jump30-raster` | frames over 30 `jumpTo` steps |
| `open-first-screen` | wall time from opening the note to the frame that shows its first text; for `source-n1` from switching to Source mode; for `paste-n1-empty-note` from the paste to the frame that shows the text; for `reload-n1-outside-edit` from the outside edit to the frame that shows it |
| `keystroke` | typing one character mid-note |
| `arrow` | Arrow Down (the text system's `moveDown:`) |
| `shift-arrow-select` | Shift-Arrow Down selection growing |
| `pointer-drag` | one step of a mouse drag-select |
| `find-bar-keystroke` | a character added to or removed from the Find query |
| `find-next-match` | a next match (Cmd-G) |
| `resize-build`, `resize-raster` | frames over 60 window-size steps |
| `select-all` | Cmd-A |
| `select-all-clear` | clicking to clear the selection |

Each matrix case scrolls twice: first with no caret in the note, recorded
under the case id, then with the caret in a row mid-note, recorded under the
case id plus `-caret` (for example `n1-plain-outline-open-spell-on-caret`),
and judged by the same Requirement.

Per metric the statistics are `count` (samples), `median`, `p90` (nearest
rank) and `max`, all in ms.

### Verdicts

Every verdict reads the **max** of the samples against the Requirement's
limit: `PASS` when it meets the limit (below it for a strict limit, such as
Requirement 6b's 100 ms), `MISS` when it does not. `INCOMPLETE` means too few
samples to judge (a Find metric needs 20 events; a metric with no frames
reported has none), or that a phase failed or was skipped: every metric a
Requirement judges for a case that ran has a row, `INCOMPLETE` when nothing
was recorded. Only the metrics a Requirement judges for a case are measured
(open and scroll frames are recorded for every case).

A scroll verdict (Requirements 3, 10 and 11, which say the scroll holds 60
fps) has a second row, `<metric> (p90)`, that reads the **p90** against the
60 fps frame budget of 16.7 ms.

The Find rows (Requirement 8) are reported on their own for N1 and N2: on
N1 a Find change lays its one 120k-character row out once, so a miss there is
recorded with its numbers, not hidden.

## Reading the numbers

Run the benchmark on an idle machine, plugged in, with nothing else
animating. Use the median and p90 to see the typical frame and the max to see
the verdict. Debug and `flutter test` numbers are not comparable: only a
profile run counts.
