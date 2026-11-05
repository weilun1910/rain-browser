# Engine round 2 | addendum to the Engine plan

Written 2026-11-05 by the Engine agent. Append this to `🌐 Browser/notes/plans/2026-11-04-engine.md` under its Status, then delete this file from the repo. The worktree can't write to `notes/` directly.

## What changed

- **Per-part reranking.** The context is cut into parts, and each part is its own meaning query. Each candidate goes to the reranker next to the part its passage matched, not next to the whole page. Before this, a long note's single query was mostly its opening lines, so a coffee chat that matched one paragraph scored near zero.
- **A wider pool.** The reranker sees the top 20 by fusion, plus the two closest items to each part of the context, up to 14 more. This is how a bridge from another space, like the Nadia coffee chat, reaches the reranker at all.
- **The gate and the order.** A card needs a reranker score of 0.7 at the default slider, a meaning score of 0.8, and retrieval agreement of at least 60% of the section's best. Cards are ordered by the reranker score plus 1.2 times that agreement. On the demo the reranker gave many items close to 1, so retrieval agreement breaks the tie.
- **Near-duplicates collapse to one card.** That covers titles that only differ by a version, an export tag or a plural, and items whose vectors are nearly identical. When two are close, the newer one wins.
- **Diversity only without the reranker.** Maximal marginal relevance made the reranker modes worse on the demo, so it's off there. It stays on when there's no reranker, where it keeps clusters of near-twins apart.
- **Passages.** Cards skip leading headings, the item's own title and metadata lines like "Date:". The passage is picked by meaning and prose quality, so navigation boxes and one-line fragments lose. The reranker reads the passage plus the next one when it's short.
- **Stable cards.** Every ranking sort breaks ties by id or word, so Swift's random dictionary order can't reorder results. Foundation Models decodes greedily. Its reading of the context now feeds only the judgment and the reasons, not retrieval, so the same context always gives the same cards.
- **Reasons.** The second sentence names noun phrases both texts share, like "Both cover cheapest channel and swap request". It falls back to distinctive single words, then to the item's own main phrase. Names, dates, numbers, title words and fragments like "sided" from two-sided are left out.
- **Clean shutdown.** Model calls run as jobs that shutdown waits for, with a time limit. Quitting stops the re-embed job and frees both models before process teardown. If a job never finishes, the exit handler skips llama.cpp's static teardown instead of crashing in it. `--quit-check` quits a child process mid-re-embed with both models loaded. With the old racy shutdown it reproduced the `GGML_ASSERT` in `ggml-metal-device.m`. Now it exits cleanly in 6 of 6 runs.
- **Tools.** `--demo-diag <profile>` shows where each labelled must item lands: fused rank, meaning, reranker score and the query it was read against. `--reasons` prints the reasons cards would show.

## Measured on a seeded copy of the demo profile

| Mode | Precision at 3 | Must recall | Distractors | Near-duplicate pairs | Time per context |
|---|---|---|---|---|---|
| Before (round-3 head e88b29f), reranker | 0.91 | 10/22 | 0 | 0 | 3.8 s |
| Before, full panel | 0.92 | 11/22 | 0 | 0 | 7.7 s |
| Now, hybrid without reranker | 0.70 | 13/22 | 0 | 0 | 0.6 s |
| Now, reranker | 0.91 | 15/22 | 0 | 0 | 3.7 s |
| Now, full panel | 0.91 | 15/22 | 0 | 0 | 7.1 s |

- Three runs in a row gave identical cards in every mode.
- On my own small fixture the reranker modes keep precision at 1.00 and stay quiet on 5 of 5. Recall there fell from 0.86 to 0.71, because short contexts give the reranker little to read and the bar is now higher. That's the trade for the demo's precision.

## Still missing on the demo

- Seven must items. Tsukemen and Andrew Chen's cold-start essay get low reranker scores even against the right part of the context. History of Facebook, the Nadia coffee chat from the draft, and the pickup points decision reach the reranker but lose to items with stronger retrieval agreement. Multi-homing evidence from the Hartley meeting is fourth in its section. The Haneda page passes in some contexts but not all.
- The remaining stray cards are plausible but unlabelled, like Saybrook College for the draft or the Network Effects Manual for the two-sided market page.
- Running the whole self test with `BROWSERPOC_MODELS_DIR` set makes other agents' checks fail, because they assume the built-in embedding. That's why the quit check reads its own variable, `BROWSERPOC_QUIT_CHECK_MODELS`.
