//! WI #76 (R3a, ruling D5): "today" follows the caller's UTC offset.
//!
//! - `Clock::utc_offset_at(now_ms)` is a default method returning the
//!   machine's local offset at that instant, so every existing clock keeps
//!   mapping dates in `Local`.
//! - `CallerClock { offset, base }` reads its instant from `base` and always
//!   answers `offset`.
//! - `daily::today_with_clock` stays the only instant-to-date mapping and asks
//!   the clock for the offset at the clock's own instant on every call (no
//!   cached date, no cached offset), so `resolve_date`, `append_to_daily_note`
//!   and the daily-title default of `create_or_adopt_note` follow it.
//! - Timestamps come from `now_ms`; the offset never shifts them.
//!
//! The local-time-zone tests that need a known zone re-run this test binary
//! with `TZ=America/New_York` (daylight saving on 2026-03-08 and 2026-11-01).

use std::cell::Cell;
use std::process::Command;

use chrono::{DateTime, FixedOffset, Local, NaiveDate, Offset, TimeZone, Utc};
use memex_core::daily::{self, AppendSource};
use memex_core::error::MemexError;
use memex_core::notes::{self, create_note_as, get_note, CreateNote};
use memex_core::{now_unix_ms, Caller, CallerClock, Clock, SystemClock, Vault};
use serde_json::json;
use tempfile::TempDir;

/// A clock pinned to one instant that does not override `utc_offset_at`.
#[derive(Debug, Clone)]
struct FixedClock(i64);

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// A base clock a test can move, backwards included.
#[derive(Debug)]
struct MovableClock(Cell<i64>);

impl MovableClock {
    fn at(rfc3339: &str) -> Self {
        Self(Cell::new(ms(rfc3339)))
    }

    fn set(&self, rfc3339: &str) {
        self.0.set(ms(rfc3339));
    }
}

impl Clock for MovableClock {
    fn now_ms(&self) -> i64 {
        self.0.get()
    }
}

/// A clock whose offset the test changes between calls (a caller crossing
/// daylight saving between two requests).
struct SwitchableOffsetClock {
    now: i64,
    offset: Cell<FixedOffset>,
}

impl Clock for SwitchableOffsetClock {
    fn now_ms(&self) -> i64 {
        self.now
    }

    fn utc_offset_at(&self, _now_ms: i64) -> FixedOffset {
        self.offset.get()
    }
}

/// A clock whose offset depends on the instant it is asked about: `after`
/// from `switch_ms` on, `before` until then.
struct InstantDependentOffsetClock {
    now: i64,
    switch_ms: i64,
    before: FixedOffset,
    after: FixedOffset,
}

impl Clock for InstantDependentOffsetClock {
    fn now_ms(&self) -> i64 {
        self.now
    }

    fn utc_offset_at(&self, now_ms: i64) -> FixedOffset {
        if now_ms >= self.switch_ms {
            self.after
        } else {
            self.before
        }
    }
}

fn ms(rfc3339: &str) -> i64 {
    DateTime::parse_from_rfc3339(rfc3339)
        .unwrap_or_else(|e| panic!("bad instant {rfc3339:?}: {e}"))
        .timestamp_millis()
}

fn offset(minutes: i32) -> FixedOffset {
    FixedOffset::east_opt(minutes * 60).unwrap_or_else(|| panic!("bad offset {minutes} min"))
}

fn date(s: &str) -> NaiveDate {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap_or_else(|e| panic!("bad date {s:?}: {e}"))
}

fn caller(minutes: i32, base: &str) -> CallerClock<FixedClock> {
    CallerClock {
        offset: offset(minutes),
        base: FixedClock(ms(base)),
    }
}

/// The machine's local offset at `now_ms`, computed independently of the
/// code under test.
fn local_offset_at(now_ms: i64) -> FixedOffset {
    let utc = DateTime::from_timestamp_millis(now_ms).unwrap().naive_utc();
    Local.offset_from_utc_datetime(&utc).fix()
}

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn daily_input(title: Option<&str>) -> CreateNote {
    CreateNote {
        title: title.map(str::to_string),
        content_md: String::new(),
        frontmatter: Some(json!({ "role": "daily" })),
    }
}

/// `2026-03-01T10:30:00Z`: AC 5's fixed base instant.
const BASE: &str = "2026-03-01T10:30:00Z";

// ---------------------------------------------------------------------------
// AC 4: the default method keeps every existing clock in local time
// ---------------------------------------------------------------------------

#[test]
fn default_utc_offset_at_is_the_local_offset_at_that_instant() {
    let instants = [
        ms("2026-01-15T12:00:00Z"),
        ms("2026-07-15T12:00:00Z"),
        ms("2026-03-08T06:59:59.999Z"),
        ms("2026-03-08T07:00:00Z"),
        ms("2026-11-01T05:59:59.999Z"),
        ms("2026-11-01T06:00:00Z"),
        now_unix_ms(),
    ];
    let clock = FixedClock(ms("2026-01-15T12:00:00Z"));
    for at in instants {
        assert_eq!(
            clock.utc_offset_at(at),
            local_offset_at(at),
            "the default utc_offset_at({at}) must be the machine's local offset at {at}"
        );
        assert_eq!(
            SystemClock.utc_offset_at(at),
            local_offset_at(at),
            "SystemClock.utc_offset_at({at}) must be the machine's local offset at {at}"
        );
    }
}

#[test]
fn today_with_system_clock_is_todays_local_date() {
    let before = Local::now().date_naive();
    let today = daily::today_with_clock(&SystemClock);
    let after = Local::now().date_naive();
    assert!(
        today == before || today == after,
        "today_with_clock(&SystemClock) = {today}, local today is {before} (or {after} across midnight)"
    );
}

#[test]
fn fixed_clock_without_override_maps_dates_in_local_time() {
    // Local noon, as append.rs's `local_noon` builds it: the local date in any zone.
    let noon = Local
        .with_ymd_and_hms(2026, 9, 5, 12, 0, 0)
        .single()
        .expect("unambiguous local noon");
    let clock = FixedClock(noon.timestamp_millis());
    assert_eq!(daily::today_with_clock(&clock), date("2026-09-05"));
    assert_eq!(
        daily::resolve_date(None, &clock).unwrap(),
        date("2026-09-05")
    );
    // Just before and at local midnight.
    let midnight = Local
        .with_ymd_and_hms(2026, 9, 6, 0, 0, 0)
        .single()
        .expect("unambiguous local midnight");
    let m = midnight.timestamp_millis();
    assert_eq!(
        daily::today_with_clock(&FixedClock(m - 1)),
        date("2026-09-05")
    );
    assert_eq!(daily::today_with_clock(&FixedClock(m)), date("2026-09-06"));
}

const TZ_CHILD_ENV: &str = "MEMEX_76_TZ_CHILD";

/// Re-runs the test `name` in this binary with `TZ=<tz>` and asserts it ran
/// and passed.
fn run_in_time_zone(name: &str, tz: &str) {
    let exe = std::env::current_exe().expect("current test binary");
    let out = Command::new(exe)
        .args([name, "--exact", "--nocapture", "--test-threads=1"])
        .env(TZ_CHILD_ENV, "1")
        .env("TZ", tz)
        .output()
        .expect("spawn the test binary");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success() && stdout.contains("1 passed"),
        "{name} under TZ={tz} failed:\n--- stdout\n{stdout}\n--- stderr\n{stderr}"
    );
}

/// New York: EST (-05:00) until 2026-03-08T07:00Z, EDT (-04:00) until
/// 2026-11-01T06:00Z, then EST again.
#[test]
fn default_utc_offset_at_follows_local_dst_at_each_instant() {
    if std::env::var_os(TZ_CHILD_ENV).is_none() {
        run_in_time_zone(
            "default_utc_offset_at_follows_local_dst_at_each_instant",
            "America/New_York",
        );
        return;
    }
    let est = offset(-300);
    let edt = offset(-240);
    assert_eq!(
        local_offset_at(ms("2026-01-15T12:00:00Z")),
        est,
        "the child must run with TZ=America/New_York"
    );

    // The offset is the one at the instant asked about, not at the clock's own instant.
    let clock = FixedClock(ms("2026-01-15T12:00:00Z"));
    assert_eq!(clock.utc_offset_at(ms("2026-03-08T06:59:59.999Z")), est);
    assert_eq!(clock.utc_offset_at(ms("2026-03-08T07:00:00Z")), edt);
    assert_eq!(clock.utc_offset_at(ms("2026-07-15T12:00:00Z")), edt);
    assert_eq!(clock.utc_offset_at(ms("2026-11-01T05:59:59.999Z")), edt);
    assert_eq!(clock.utc_offset_at(ms("2026-11-01T06:00:00Z")), est);
    assert_eq!(SystemClock.utc_offset_at(ms("2026-07-15T12:00:00Z")), edt);

    // The local date differs from the UTC date in the evening.
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-03-01T03:00:00Z"))),
        date("2026-02-28")
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-03-01T04:59:59.999Z"))),
        date("2026-02-28")
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-03-01T05:00:00Z"))),
        date("2026-03-01")
    );
    // Local midnight under EDT is 04:00Z, under EST 05:00Z.
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-07-16T03:59:59.999Z"))),
        date("2026-07-15")
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-07-16T04:00:00Z"))),
        date("2026-07-16")
    );
    assert_eq!(
        daily::today_with_clock(&FixedClock(ms("2026-11-02T04:30:00Z"))),
        date("2026-11-01"),
        "after DST ends, 04:30Z is 23:30 EST on 2026-11-01"
    );

    // Backward jumps: the same clock moved back re-reads date and offset.
    let moving = MovableClock::at("2026-03-01T05:00:30Z");
    assert_eq!(daily::today_with_clock(&moving), date("2026-03-01"));
    moving.set("2026-03-01T04:59:30Z");
    assert_eq!(daily::today_with_clock(&moving), date("2026-02-28"));
    moving.set("2026-11-01T06:00:00Z");
    assert_eq!(moving.utc_offset_at(moving.now_ms()), est);
    moving.set("2026-11-01T05:59:59Z");
    assert_eq!(
        moving.utc_offset_at(moving.now_ms()),
        edt,
        "back across the fall-back instant the offset is EDT again"
    );
    assert_eq!(daily::today_with_clock(&moving), date("2026-11-01"));
}

// ---------------------------------------------------------------------------
// today_with_clock asks the clock (any clock) for the offset, every call
// ---------------------------------------------------------------------------

#[test]
fn today_with_clock_asks_the_offset_at_the_clock_instant() {
    let switch_ms = ms(BASE);
    let at = |now: i64| InstantDependentOffsetClock {
        now,
        switch_ms,
        before: offset(-720),
        after: offset(840),
    };
    assert_eq!(daily::today_with_clock(&at(switch_ms)), date("2026-03-02"));
    assert_eq!(
        daily::today_with_clock(&at(switch_ms - 1)),
        date("2026-02-28")
    );
}

#[test]
fn today_with_clock_rereads_the_offset_on_every_call() {
    let clock = SwitchableOffsetClock {
        now: ms("2026-03-01T23:30:00Z"),
        offset: Cell::new(offset(0)),
    };
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-01"));
    clock.offset.set(offset(60));
    assert_eq!(
        daily::today_with_clock(&clock),
        date("2026-03-02"),
        "a changed offset at the same instant must change today (nothing cached)"
    );
    clock.offset.set(offset(0));
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-01"));
}

/// A clock whose instant advances on every `now_ms` read (a real clock
/// ticking between two reads), with an offset that changes at `switch_ms`.
/// It records every read and every instant `utc_offset_at` is asked about.
struct TickingClock {
    ticks: std::cell::RefCell<Vec<i64>>,
    switch_ms: i64,
    before: FixedOffset,
    after: FixedOffset,
    asked: std::cell::RefCell<Vec<i64>>,
    reads: Cell<usize>,
}

impl TickingClock {
    fn new(ticks: &[&str], switch: &str, before: i32, after: i32) -> Self {
        Self {
            ticks: std::cell::RefCell::new(ticks.iter().rev().map(|t| ms(t)).collect()),
            switch_ms: ms(switch),
            before: offset(before),
            after: offset(after),
            asked: std::cell::RefCell::new(Vec::new()),
            reads: Cell::new(0),
        }
    }
}

impl Clock for TickingClock {
    fn now_ms(&self) -> i64 {
        self.reads.set(self.reads.get() + 1);
        let mut ticks = self.ticks.borrow_mut();
        // Past the last tick the clock stays on it.
        if ticks.len() > 1 {
            ticks.pop().unwrap()
        } else {
            *ticks.last().expect("at least one tick")
        }
    }

    fn utc_offset_at(&self, now_ms: i64) -> FixedOffset {
        self.asked.borrow_mut().push(now_ms);
        if now_ms >= self.switch_ms {
            self.after
        } else {
            self.before
        }
    }
}

/// `today_with_clock` reads the instant once per call and asks the offset at
/// that same instant: it never maps one instant with the offset of another.
/// Ticks 23:30Z then 00:30Z, offset +00:00 before 00:00Z and +01:00 after.
/// Read once, the first tick at +00:00 is 2026-03-01; any mix of the two
/// ticks (date of one, offset of the other, or the second tick) is 2026-03-02.
#[test]
fn today_with_clock_reads_the_instant_once_per_call() {
    let ticks = ["2026-03-01T23:30:00Z", "2026-03-02T00:30:00Z"];
    let clock = TickingClock::new(&ticks, "2026-03-02T00:00:00Z", 0, 60);
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-01"));
    assert_eq!(clock.reads.get(), 1, "now_ms is read once per call");
    assert_eq!(
        *clock.asked.borrow(),
        vec![ms(ticks[0])],
        "the offset is asked at the instant that was read"
    );
    // The next call reads the next instant (nothing cached).
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-02"));
    assert_eq!(clock.reads.get(), 2);
    assert_eq!(*clock.asked.borrow(), vec![ms(ticks[0]), ms(ticks[1])]);

    // Through a CallerClock the base is read once too.
    let caller_clock = CallerClock {
        offset: offset(0),
        base: TickingClock::new(&ticks, "2026-03-02T00:00:00Z", 0, 60),
    };
    assert_eq!(daily::today_with_clock(&caller_clock), date("2026-03-01"));
    assert_eq!(caller_clock.base.reads.get(), 1, "the base is read once");
    assert!(
        caller_clock.base.asked.borrow().is_empty(),
        "a CallerClock never asks its base for an offset"
    );
}

// ---------------------------------------------------------------------------
// AC 5-7: CallerClock
// ---------------------------------------------------------------------------

#[test]
fn caller_clock_today_follows_the_caller_offset() {
    let cases = [
        (840, "2026-03-02"),
        (-720, "2026-02-28"),
        (0, "2026-03-01"),
        (-840, "2026-02-28"),
        (345, "2026-03-01"),
    ];
    for (minutes, expected) in cases {
        assert_eq!(
            daily::today_with_clock(&caller(minutes, BASE)),
            date(expected),
            "today at {minutes:+} min with base {BASE}"
        );
    }
}

#[test]
fn caller_clock_today_turns_over_at_caller_midnight() {
    let cases = [
        (0, "2026-03-01T23:59:59.999Z", "2026-03-01"),
        (0, "2026-03-02T00:00:00Z", "2026-03-02"),
        (-30, "2026-03-02T00:15:00Z", "2026-03-01"),
        (-30, "2026-03-02T00:29:59.999Z", "2026-03-01"),
        (-30, "2026-03-02T00:30:00Z", "2026-03-02"),
        (840, "2026-03-01T09:59:59.999Z", "2026-03-01"),
        (840, "2026-03-01T10:00:00Z", "2026-03-02"),
        (-720, "2026-03-02T11:59:59.999Z", "2026-03-01"),
        (-720, "2026-03-02T12:00:00Z", "2026-03-02"),
    ];
    for (minutes, base, expected) in cases {
        assert_eq!(
            daily::today_with_clock(&caller(minutes, base)),
            date(expected),
            "today at {minutes:+} min with base {base}"
        );
    }
}

#[test]
fn caller_clock_backward_jump_recomputes_today() {
    let clock = CallerClock {
        offset: offset(0),
        base: MovableClock::at("2026-03-02T00:00:30Z"),
    };
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-02"));
    clock.base.set("2026-03-01T23:59:30Z");
    assert_eq!(
        daily::today_with_clock(&clock),
        date("2026-03-01"),
        "after the base clock jumps back across midnight, today is the earlier day"
    );
    assert_eq!(clock.now_ms(), ms("2026-03-01T23:59:30Z"));
    clock.base.set("2026-03-02T00:00:30Z");
    assert_eq!(daily::today_with_clock(&clock), date("2026-03-02"));
}

#[test]
fn caller_clock_utc_offset_at_is_the_fixed_caller_offset() {
    for minutes in [-840, -720, -570, -30, 0, 330, 345, 840] {
        let clock = caller(minutes, BASE);
        for at in [
            ms(BASE),
            ms("2026-03-08T07:00:00Z"),
            ms("2026-07-15T12:00:00Z"),
            ms("2026-11-01T06:00:00Z"),
            0,
        ] {
            assert_eq!(
                clock.utc_offset_at(at),
                offset(minutes),
                "CallerClock at {minutes:+} min answers its own offset at {at}"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// AC 11: the instant comes from the base
// ---------------------------------------------------------------------------

#[test]
fn caller_clock_now_ms_is_the_base_instant() {
    for minutes in [-840, -30, 0, 840] {
        let clock = caller(minutes, BASE);
        assert_eq!(clock.now_ms(), ms(BASE), "offset {minutes:+} min");
    }
    let moving = CallerClock {
        offset: offset(840),
        base: MovableClock::at(BASE),
    };
    assert_eq!(moving.now_ms(), ms(BASE));
    moving.base.set("2026-03-01T10:29:00Z");
    assert_eq!(moving.now_ms(), ms("2026-03-01T10:29:00Z"));
}

#[test]
fn caller_clock_over_system_clock_reads_the_system_instant() {
    for minutes in [840, -720] {
        let clock = CallerClock {
            offset: offset(minutes),
            base: SystemClock,
        };
        let before = now_unix_ms();
        let now = clock.now_ms();
        let today = daily::today_with_clock(&clock);
        let after = now_unix_ms();
        assert!(
            (before..=after).contains(&now),
            "CallerClock over SystemClock: now_ms {now} outside [{before}, {after}]"
        );
        let caller_today = |at: i64| {
            DateTime::<Utc>::from_timestamp_millis(at)
                .unwrap()
                .with_timezone(&offset(minutes))
                .date_naive()
        };
        assert!(
            today == caller_today(before) || today == caller_today(after),
            "today {today} must be the date at {minutes:+} min"
        );
    }
}

#[test]
fn caller_clock_offset_never_shifts_created_at() {
    for minutes in [840, -720, -30] {
        let (_dir, mut vault) = fresh_vault();
        let clock = caller(minutes, BASE);
        let plain = notes::create_or_adopt_note(
            &mut vault,
            CreateNote {
                title: Some(format!("plain {minutes}")),
                content_md: "body".into(),
                frontmatter: None,
            },
            Caller::Person,
            &clock,
        )
        .unwrap()
        .note;
        assert_eq!(plain.created_at, ms(BASE), "created_at at {minutes:+} min");
        assert_eq!(plain.updated_at, ms(BASE), "updated_at at {minutes:+} min");

        let day = notes::create_or_adopt_note(&mut vault, daily_input(None), Caller::Agent, &clock)
            .unwrap()
            .note;
        assert_eq!(
            day.created_at,
            ms(BASE),
            "daily created_at at {minutes:+} min"
        );
    }
}

// ---------------------------------------------------------------------------
// AC 8: resolve_date
// ---------------------------------------------------------------------------

#[test]
fn resolve_date_none_follows_the_caller_offset() {
    assert_eq!(
        daily::resolve_date(None, &caller(840, BASE)).unwrap(),
        date("2026-03-02")
    );
    assert_eq!(
        daily::resolve_date(None, &caller(-720, BASE)).unwrap(),
        date("2026-02-28")
    );
    assert_eq!(
        daily::resolve_date(None, &caller(-30, "2026-03-02T00:15:00Z")).unwrap(),
        date("2026-03-01")
    );
}

#[test]
fn resolve_date_some_ignores_the_caller_clock() {
    for minutes in [840, -720, 0] {
        assert_eq!(
            daily::resolve_date(Some("2026-03-01"), &caller(minutes, BASE)).unwrap(),
            date("2026-03-01"),
            "an explicit date at {minutes:+} min"
        );
    }
}

#[test]
fn resolve_date_malformed_is_still_invalid_date() {
    for bad in ["2026-3-1", "2026-02-30", "", "2026-03-01T00:00", "tomorrow"] {
        match daily::resolve_date(Some(bad), &caller(840, BASE)) {
            Err(MemexError::InvalidDate(_)) => {}
            other => panic!("resolve_date({bad:?}) = {other:?}, want InvalidDate"),
        }
    }
}

// ---------------------------------------------------------------------------
// AC 9: create_or_adopt_note's daily-title default
// ---------------------------------------------------------------------------

#[test]
fn create_daily_without_title_uses_caller_today() {
    let (_dir, mut vault) = fresh_vault();
    let outcome = notes::create_or_adopt_note(
        &mut vault,
        daily_input(None),
        Caller::Person,
        &caller(840, BASE),
    )
    .unwrap();
    assert_eq!(outcome.note.title, "2026-03-02");
    assert!(!outcome.adopted);
    assert!(daily::is_daily(&outcome.note.frontmatter));

    let behind = notes::create_or_adopt_note(
        &mut vault,
        daily_input(None),
        Caller::Agent,
        &caller(-720, BASE),
    )
    .unwrap();
    assert_eq!(behind.note.title, "2026-02-28");

    let half_hour = notes::create_or_adopt_note(
        &mut vault,
        daily_input(None),
        Caller::Agent,
        &caller(-30, "2026-03-02T00:15:00Z"),
    )
    .unwrap();
    assert_eq!(half_hour.note.title, "2026-03-01");
}

#[test]
fn create_daily_with_explicit_title_ignores_caller_offset() {
    let (_dir, mut vault) = fresh_vault();
    let outcome = notes::create_or_adopt_note(
        &mut vault,
        daily_input(Some("2026-03-01")),
        Caller::Person,
        &caller(840, BASE),
    )
    .unwrap();
    assert_eq!(outcome.note.title, "2026-03-01");
}

// ---------------------------------------------------------------------------
// AC 10: append_to_daily_note with no date
// ---------------------------------------------------------------------------

#[test]
fn append_without_date_creates_caller_today_daily_note() {
    let (_dir, mut vault) = fresh_vault();
    let outcome = daily::append_to_daily_note(
        &mut vault,
        "from the far east",
        None,
        AppendSource::QuickEntry,
        &caller(840, BASE),
        None,
    )
    .unwrap();
    assert_eq!(outcome.date, date("2026-03-02"));
    assert_eq!(outcome.note.title, "2026-03-02");
    assert!(daily::is_daily(&outcome.note.frontmatter));
    let stored = get_note(&vault, &outcome.note.id).unwrap();
    assert!(
        stored.content_md.contains("from the far east"),
        "the appended text is in the 2026-03-02 daily note: {:?}",
        stored.content_md
    );
}

#[test]
fn append_without_date_targets_existing_caller_today_daily_note() {
    let (_dir, mut vault) = fresh_vault();
    let utc_day =
        create_note_as(&mut vault, daily_input(Some("2026-03-01")), Caller::Person).unwrap();
    let caller_day =
        create_note_as(&mut vault, daily_input(Some("2026-03-02")), Caller::Person).unwrap();

    let outcome = daily::append_to_daily_note(
        &mut vault,
        "agent line",
        None,
        AppendSource::Agent,
        &caller(840, BASE),
        None,
    )
    .unwrap();
    assert_eq!(outcome.note.id, caller_day.id);
    assert_eq!(outcome.date, date("2026-03-02"));
    assert!(get_note(&vault, &caller_day.id)
        .unwrap()
        .content_md
        .contains("agent line"));
    let untouched = get_note(&vault, &utc_day.id).unwrap();
    assert_eq!(untouched.version, utc_day.version);
    assert!(!untouched.content_md.contains("agent line"));

    let behind = daily::append_to_daily_note(
        &mut vault,
        "west line",
        None,
        AppendSource::Agent,
        &caller(-720, BASE),
        None,
    )
    .unwrap();
    assert_eq!(behind.date, date("2026-02-28"));
    assert_eq!(behind.note.title, "2026-02-28");
}
