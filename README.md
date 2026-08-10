# Reading Calendar — SimpleUI homescreen module for KOReader

A month-view calendar for the [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin)
homescreen. Every day you read shows the **cover(s) of the book(s) you read
that day** — when you read multiple books in one day, the covers **stack**
with a small fanned offset. Days without reading show a plain day number.

A stats strip at the top shows the month's totals:

```
        2026
        JULY
  27      2987      272
 BOOKS    PAGES   PAGES/DAY
```

`PAGES/DAY` is pages divided by the number of days you actually read.

All data comes from KOReader's built-in statistics database — nothing extra
to track. Covers come from SimpleUI's cover cache.

## Install

You need the SimpleUI plugin installed. Then pick **one** of these:

### Option A — you have [simpleui_ext](https://github.com/omer-faruq/simpleui_ext.koplugin)

Copy `module_reading_calendar.lua` into:

```
koreader/plugins/simpleui_ext.koplugin/modules/
```

Restart KOReader. It is auto-registered.

### Option B — SimpleUI only (no simpleui_ext)

Copy the whole `readingcalendar.koplugin/` folder into:

```
koreader/plugins/
```

Restart KOReader.

Either way, the module appears on your homescreen (you can position or
disable it from SimpleUI's Arrange/module settings, id `reading_calendar`).

## Interactions

| Gesture | Action |
| --- | --- |
| Swipe left / right on the calendar | Next / previous month |
| Tap left / right side of the header | Previous / next month |
| Tap the month name | Jump back to the current month |
| Tap a day with covers | Popup listing that day's books, pages and time |

You cannot navigate past the current month.

## Settings

Long-press the module (SimpleUI module menu):

- **Start week on Monday** — default is Sunday-first, like the screenshot.
- **Scale** — standard SimpleUI module scaling.

Up to 3 covers stack per day (the most-read book is on top).

## How covers are found

The statistics database stores a checksum per book, not a file path. The
module resolves checksums to files by scanning your reading history's
sidecar metadata once, then caches the mapping persistently
(`reading_calendar_map.lua` in the KOReader data folder). Books whose file
has been deleted or removed from history fall back to a mini title-card
placeholder. Covers extracted in the background pop in automatically.
