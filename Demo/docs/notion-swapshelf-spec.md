---
id: notion-swapshelf-spec
title: "Spec: listings and pickup points"
source: notion
space: swapshelf
created: 2026-10-18T14:00:00-04:00
edited: 2026-10-22T01:30:00-04:00
owner: Theo Park
shared_with: [Sam Okoro]
origin_url: https://www.notion.so/demo-swapshelf-spec
demo_url: demo://notion/notion-swapshelf-spec
---

# Spec: listings and pickup points

Status: agreed Oct 21. Builds on the pickup points decision.

## Listing an item
1. Tap +, pick textbook or gear
2. Textbook: scan the ISBN barcode, title and edition fill in. Gear: type a title.
3. One photo, required. Condition: like new, used, well loved.
4. Post. It shows to everyone in your college right away.

Target: under 60 seconds from tap to posted. We timed ourselves at 40.

## Requesting an item
1. Tap Request. A credit is held, not spent.
2. The lister gets a push notification and has 24 hours to drop it on their buttery shelf.
3. When the lister taps "On the shelf", the requester gets a four-digit pickup code.
4. Requester picks it up and taps "Got it". The credit moves.

If nobody drops it off within 24 hours, or nobody picks it up within 72, the hold expires and the credit comes back.

## Pickup points
- One shelf per buttery, Branford and Saybrook
- A tag on each item with the four-digit code and the requester's first name
- Big items (fridges, chairs) skip the shelf and use a handoff with a time picked in the app

## Edge cases
- Item missing from the shelf: requester taps "Not there". Lister is asked to check. Two misses and we look into it by hand.
- Lister withdraws after a request: credit returns right away
- Same item requested by two people: first request wins, second gets "Just taken"

## Out of scope for the pilot
- Messaging between users
- Multiple photos
- Search across colleges
