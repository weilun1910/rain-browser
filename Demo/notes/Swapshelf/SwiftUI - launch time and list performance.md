---
id: note-swiftui-launch
title: SwiftUI - launch time and list performance
space: swapshelf
created: 2026-10-23T00:50:00-04:00
updated: 2026-10-23T02:15:00-04:00
tags: [swapshelf, ios, performance]
---

# SwiftUI - launch time and list performance

The TestFlight build felt slow to open on Sam's iPhone 12. Measured it instead of guessing.

## Cold start vs warm start
- Cold start is the first launch after a reboot, or after the system has pushed the app out of memory. Nothing is cached, dyld has to load everything.
- Warm start is when the app's binary and frameworks are still in memory.
- Cold launch to first frame was about 1.9 s on the iPhone 12. Warm launch was about 0.6 s.

## What was slow
- Creating the Supabase client and restoring the session on the main thread, inside the App init
- A big asset catalog image on the onboarding screen
- Fetching the first page of listings before showing anything

## Fixes
- Moved client setup and session restore into a task after the first frame
- Show cached listings from SwiftData right away, refresh in the background
- Replaced the onboarding image with an SF Symbol and a gradient

After: cold launch about 0.9 s. Good enough for the pilot.

## List performance
- The listings List stuttered with 300 rows of images
- AsyncImage was refetching thumbnails while scrolling. Added a small in-memory cache keyed by listing id
- Gave each row a stable id so SwiftUI stops rebuilding rows

Use the App Launch template in Instruments next time instead of print timestamps.
