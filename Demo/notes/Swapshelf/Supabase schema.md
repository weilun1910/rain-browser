---
id: note-supabase-schema
title: Supabase schema
space: swapshelf
created: 2026-10-02T22:30:00-04:00
updated: 2026-10-16T01:05:00-04:00
tags: [swapshelf, backend, supabase]
---

# Supabase schema

Postgres on Supabase. Auth is magic link to a yale.edu address only.

## Tables

**profiles**
- id (uuid, same as auth user)
- display_name
- college (text, one of the fourteen)
- class_year
- credits (int, starts at 1 so new people can take something first)

**listings**
- id, owner_id
- kind: textbook or gear
- title, isbn (nullable), condition, photo_path
- college
- status: available, held, picked_up, withdrawn
- created_at

**swaps**
- id, listing_id, requester_id
- status: requested, ready, picked_up, expired
- pickup_code (four digits)
- pickup_point: branford_buttery, saybrook_buttery, handoff
- requested_at, picked_up_at
- unique (listing_id, requester_id) so nobody double-requests

## Row level security
- During the pilot, you can only read listings in your own college. Policy compares listings.college to your profile's college.
- You can only update your own listings.
- Swaps are visible to the lister and the requester, nobody else.

## Notes to self
- Holds expire after 72 hours. A scheduled function flips swaps to expired and the listing back to available.
- Don't store the pickup code in the listing, only in the swap row.
- Postgres check constraint on credits >= 0 so a race can't take anyone negative.
