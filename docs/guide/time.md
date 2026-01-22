# Date and Time

Tokamak includes a date and time library for working with dates, times, and timestamps.

## Quick Start

```zig
const tk = @import("tokamak");

// Current time
const now = tk.time.Time.now();
const today = tk.time.Date.today();

// Create specific dates and times
const birthday = tk.time.Date.ymd(1990, 6, 15);
const meeting = tk.time.Time.unix(1234567890);

// Parse from string
const date = try tk.time.Date.parse("2024-12-25");
```

## Working with Dates

### Creating Dates

```zig
// Specific date
const d = tk.time.Date.ymd(2024, 3, 15);

// Current date
const today = tk.time.Date.today();

// Relative dates
const yesterday = tk.time.Date.yesterday();
const tomorrow = tk.time.Date.tomorrow();

// Parse ISO 8601 format
const parsed = try tk.time.Date.parse("2024-03-15");
```

### Date Arithmetic

```zig
const d = tk.time.Date.ymd(2024, 3, 15);

// Add or subtract days, months, years
const next_week = d.add(.day, 7);
const next_month = d.add(.month, 1);
const next_year = d.add(.year, 1);

// Subtract using negative values
const last_week = d.add(.day, -7);
const last_month = d.add(.month, -1);
```

> **Tip:** Month-End Handling
>
> When adding months to a date that doesn't exist in the target month, the day is automatically clamped:
>
> ```zig
> const jan31 = tk.time.Date.ymd(2024, 1, 31);
> const feb = jan31.add(.month, 1);  // 2024-02-29 (leap year)
> ```

### Period Start and End

```zig
const d = tk.time.Date.ymd(2024, 3, 15);

// Start of period
const month_start = d.setStartOf(.month);  // 2024-03-01
const year_start = d.setStartOf(.year);    // 2024-01-01

// End of period
const month_end = d.setEndOf(.month);      // 2024-03-31
const year_end = d.setEndOf(.year);        // 2024-12-31
```

## Working with Times

### Creating Times

```zig
// Current time
const now = tk.time.Time.now();

// From Unix timestamp
const t = tk.time.Time.unix(1234567890);

// Midnight today/tomorrow
const today = tk.time.Time.today();
const tomorrow = tk.time.Time.tomorrow();
```

### Extracting Components

```zig
const t = tk.time.Time.unix(1234567890);

// Get date part
const date = t.date();  // tk.time.Date.ymd(2009, 2, 13)

// Get time components
const hour = t.hour();      // 23
const minute = t.minute();  // 31
const second = t.second();  // 30
```

### Time Arithmetic

```zig
const t = tk.time.Time.now();

// Add time units
const in_5_minutes = t.add(.minutes, 5);
const in_2_hours = t.add(.hours, 2);
const tomorrow = t.add(.days, 1);

// Combine operations
const later = t.add(.hours, 2).add(.minutes, 30);
```

### Setting Components

```zig
const t = tk.time.Time.now();

// Set specific time of day
const at_noon = t.setHour(12).setMinute(0).setSecond(0);

// Set date while preserving time-of-day
const christmas = tk.time.Date.ymd(2024, 12, 25);
const christmas_at_current_time = t.setDate(christmas);
```

### Period Boundaries

```zig
const t = tk.time.Time.now();

// Start of period
const day_start = t.setStartOf(.day);       // Today at 00:00:00
const month_start = t.setStartOf(.month);   // First day at 00:00:00
const year_start = t.setStartOf(.year);     // Jan 1 at 00:00:00

// End of period
const day_end = t.setEndOf(.day);           // Today at 23:59:59
const month_end = t.setEndOf(.month);       // Last day at 23:59:59
const year_end = t.setEndOf(.year);         // Dec 31 at 23:59:59
```

## Common Patterns

### Date Ranges

```zig
// Iterate through a date range
const start = tk.time.Date.ymd(2024, 1, 1);
const end = tk.time.Date.ymd(2024, 1, 31);

var current = start;
while (current.cmp(end) != .gt) {
    // Process each date
    std.debug.print("{f}\n", .{current});
    current = current.add(.day, 1);
}
```

### Last Month's Report

```zig
const now = tk.time.Date.today();
const month_start = now.setStartOf(.month).add(.month, -1);
const month_end = month_start.setEndOf(.month);

const report_period = .{
    .start = tk.time.Time.unix(0).setDate(month_start),
    .end = tk.time.Time.unix(0).setDate(month_end),
};
```

### Scheduling Tasks

```zig
// Schedule task 5 minutes from now
const task_time = tk.time.Time.now().add(.minutes, 5);

// Store as Unix timestamp
const task = Task{
    .scheduled_at = task_time.epoch,
    .name = "Send reminder email",
};
```

### Retry with Backoff

```zig
// Exponential backoff
const failed_time = tk.time.Time.now();
const retry_delay = std.math.pow(i64, 2, attempt_count);
const next_retry = failed_time.add(.minutes, retry_delay);
```

## Formatting

Dates and times have default string formats:

```zig
const d = tk.time.Date.ymd(2024, 3, 15);
const t = tk.time.Time.unix(1234567890);

// Use {f} format specifier
try writer.print("Date: {f}\n", .{d});
// Output: Date: 2024-03-15

try writer.print("Time: {f}\n", .{t});
// Output: Time: 2009-02-13 23:31:30 UTC
```

## Comparison

```zig
const d1 = tk.time.Date.ymd(2024, 3, 15);
const d2 = tk.time.Date.ymd(2024, 3, 16);

// Compare dates
const order = d1.cmp(d2);  // .lt, .eq, or .gt

// Compare times (as integers)
const t1 = tk.time.Time.unix(100);
const t2 = tk.time.Time.unix(200);

if (t1.epoch < t2.epoch) {
    // t1 is earlier
}
```

## Leap Years

Leap years are handled automatically:

```zig
// Check if year is leap year
if (tk.time.isLeapYear(2024)) {
    // 2024 is a leap year
}

// Automatic handling in date operations
const jan31 = tk.time.Date.ymd(2024, 1, 31);
const feb = jan31.add(.month, 1);  // 2024-02-29 (auto-clamped)

const jan31_2023 = tk.time.Date.ymd(2023, 1, 31);
const feb_2023 = jan31_2023.add(.month, 1);  // 2023-02-28
```

## Important Notes

> **Warning:** UTC Only
>
> All times are in UTC. There is no timezone support. If you need timezone conversions, handle them manually:
>
> ```zig
> const utc = tk.time.Time.now();
> const offset = 5 * 3600;  // UTC+5
> const local = utc.add(.seconds, offset);
> ```

> **Warning:** Second Precision
>
> Times have second precision only. For subsecond timing (benchmarks, profiling), use `std.time.nanoTimestamp()` instead.
