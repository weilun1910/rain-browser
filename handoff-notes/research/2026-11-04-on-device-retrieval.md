# On-device retrieval for resurfacing | research

Written 2026-11-05 by the Engine agent for round 3. It covers the runtime, the models, Apple's own frameworks, vector search and the judging step. The sources (Granola, Notion, Google Docs) are in [2026-11-04-sources.md](2026-11-04-sources.md).

Labels: **Tested** means I ran it on Felix's M4 Pro (24 GB, macOS 27.0.1, Xcode 26.2 SDK). **Doc** means a vendor page, model card, header file or PR says it. **Inference** means my own reasoning.

## What the POC did before round 3

- `NLEmbedding.sentenceEmbedding` gave one static vector per passage. It is Apple's older sentence model and is weak on technical text.
- `NLTagger` found names. Keyword overlap used hand-built TF-IDF over FTS5's vocabulary.
- `IndexStore.retrieve` mixed keyword, meaning and name scores with hand-tuned weights and a threshold slider.
- Foundation Models only wrote the reason line after ranking. No model ever judged relevance.

## The runtime: llama.cpp as a SwiftPM binary target

- **Tested.** The official llama.cpp release ships `llama-<build>-xcframework.zip` (76 MB for b12121, released 2026-11-05). A SwiftPM `.binaryTarget(url:checksum:)` pointing at it builds with plain `swift build`. The checksum is the sha256 GitHub lists as the asset digest (`00bc6fec00beba802a3912a6afb81e1678da5248a6a92548a9ce66724a3e7638`).
- **Tested.** Metal works with no shader step, because the framework embeds its Metal library (`MTL : EMBED_LIBRARY = 1` in `llama_print_system_info`). This avoids the mlx-swift trap, where SwiftPM on the command line can't compile `.metal` files.
- **Tested.** The framework is dynamic and linked through `@rpath`. SwiftPM copies `llama.framework` next to the debug binary, so `--selftest` runs as is. The release app needs it copied into `Contents/Frameworks` with an extra rpath, which `scripts/build.sh` now does.
- **Tested.** The first `swift build` printed "Failed to find credentials for 'https://github.com' in keychain: status -128" and then downloaded the file anyway. `swift build --disable-keychain` skips that lookup. It is a warning, not a failure.
- **Doc.** `llama.h` in b12121 has everything needed: `llama_model_n_embd_out` (the output size for models with a projection), `LLAMA_POOLING_TYPE_RANK`, `llama_model_n_cls_out`, `llama_model_chat_template(model, "rerank")` and `llama_get_embeddings_seq`.
- Releases: https://github.com/ggml-org/llama.cpp/releases/tag/b12121 | XCFramework section of the README: https://github.com/ggml-org/llama.cpp#xcframework

Other routes I looked at:
- **mlx-swift** needs its Metal shaders compiled by Xcode. Plain `swift build` doesn't do that, so it fails at runtime without extra build steps. Ruled out for this package.
- **Core ML** works with SwiftPM, but every model needs a conversion step and there are no official Core ML builds of the current small embedders and rerankers. A community Core ML EmbeddingGemma 2 exists (https://huggingface.co/delavalom/embeddinggemma-2-coreml). Worth revisiting for the Neural Engine later.
- **NLContextualEmbedding** (Apple, built in). **Tested:** 512 dimensions, 256 tokens maximum, assets already on the Mac, 17 ms for a short sentence. It returns one vector per token, so we mean-pool. It is the fallback while the models download or if they fail.

## Apple Foundation Models

- **Doc (Xcode 26.2 SDK, which `scripts/build.sh` pins).** `FoundationModels` has `LanguageModelSession`, guided generation with `@Generable` and `@Guide`, `SystemLanguageModel(useCase: .contentTagging)` and adapters. There is no embedding API and no reranking API.
- **Doc (macOS 27 SDK in the Command Line Tools).** macOS 27 adds `contextSize`, `tokenCount(for:)` and a `PrivateCloudComputeLanguageModel`. Private Cloud Compute is not on device, so it's out. Still no embeddings. We build against 26.2, so none of the 27 API is used.
- **Tested.** Guided generation of a working-context description (topic, intent, entities, 3 queries) from a 450-character note took 2.7 s. The `.contentTagging` model took 3.7 s and pulled out better entities ("Zen's Glance", "Vannevar Bush memex essay") where the general model returned single words.
- **Tested.** A strict yes/no judgment with confidence and a reason took 1.0 to 1.3 s per item. With a naive prompt it called a clearly relevant study "not directly related". The on-device model is too literal to be the only gate. It works as one signal on top of the reranker, with a prompt that gives it the user's own text and the passage side by side.
- **Doc.** The on-device model's context window is 4,096 tokens (Apple TN3193: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window). So the working-context prompt sends a trimmed window: title, selection, the text around the cursor and the start of the visible text.

## Models

Full comparison from a research pass on 2026-11-05. MTEB numbers are from the model cards. Retrieval averages were recomputed from the MTEB results repo (https://github.com/embeddings-benchmark/results) and match the published numbers where both exist.

### Embedding

| Model | Licence | Size on disk | Dims | Context | MTEB eng v2 | Notes |
|---|---|---|---|---|---|---|
| **EmbeddingGemma 2** (`ggml-org/embeddinggemma-2-GGUF`, Q8_0) | Apache 2.0 | 310 MB | 768 (MRL to 512, 256, 128) | 8,192 | 68.46 | llama.cpp arch `gemma-embedding2` since b11452. Released 2026-09-14. |
| EmbeddingGemma-300M (Q8_0) | Gemma Terms of Use | 334 MB | 768 | 2,048 | 69.67 | Licence carries use restrictions and a remote-restriction clause. |
| Qwen3-Embedding-0.6B (Q8_0) | Apache 2.0 | 639 MB | 1,024 | 32K | 70.70 | Best retrieval (61.8) but twice the size and about half the speed. |
| nomic-embed-text-v2-moe | Apache 2.0 | | 768 | 512 | 63.64 | Short context. |
| NLContextualEmbedding | built in | 0 | 512 | 256 | not published | Fallback. |

- EmbeddingGemma 2 card: https://huggingface.co/google/embeddinggemma-2 | developer guide: https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/ | llama.cpp PR #30054: https://github.com/ggml-org/llama.cpp/pull/30054
- Gemma Terms (for the 300M model): https://ai.google.dev/gemma/terms
- **Doc.** Prompt formats: queries `task: search result | query: {text}`, documents `title: {title or none} | text: {text}`. Mean pooling. Normalise after pooling. Never fp16 activations.
- **Tested.** On the M4 Pro it loads in about 4 s the first time (0.3 s warm) and embeds 64 passages of 219 tokens in 1.35 s, about 10,000 tokens per second. A WebKit query scored 0.79 and 0.76 cosine against two WebKit passages and 0.47 against sourdough and marathon passages.

### Reranker

| Model | Licence | Size | Quality | llama.cpp |
|---|---|---|---|---|
| **Qwen3-Reranker-0.6B** (`giladgd/Qwen3-Reranker-0.6B-GGUF`, Q4_K_M) | Apache 2.0 | 396 MB | MTEB-R 65.80 | Rank pooling since PR #15824, if the GGUF carries the yes/no head |
| bge-reranker-v2-m3 | Apache 2.0 | about 600 MB at Q8 | MTEB-R 57.03 | Supported |
| gte-reranker-modernbert-base (Q8_0) | Apache 2.0 | 161 MB | BEIR 56.19, English only | Supported, sigmoid on one logit |
| mxbai-rerank-base-v2 | Apache 2.0 | | BEIR 55.57 | No rerank path in llama.cpp |
| jina rerankers v2 and v3 | CC BY-NC 4.0 | | | Not usable in a product |

- Qwen3-Reranker card: https://huggingface.co/Qwen/Qwen3-Reranker-0.6B | llama.cpp support: https://github.com/ggml-org/llama.cpp/pull/15824 | broken older conversions: https://github.com/ggml-org/llama.cpp/issues/25447
- **Doc.** Many Qwen3-Reranker GGUFs converted before September 2025 lack the classifier head and score everything near zero. The `giladgd` and `ggml-org` files have it.
- **Tested.** The `giladgd` Q4_K_M file loads with a 2-output head and its own rerank template. A WebKit query scored the WKWebExtension passage 0.97, the Nook CRX passage 0.66, sourdough 0.00002 and marathon 0.0001. Twenty passages of about 250 tokens took 1.16 s.

### Decision

- Embedding: EmbeddingGemma 2 Q8_0, 309,855,456 bytes, sha256 `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135`, from `https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/embeddinggemma-2-Q8_0.gguf`.
- Reranker: Qwen3-Reranker-0.6B Q4_K_M, 396,476,320 bytes, sha256 `046ccc0b4cb9be503b3320bfaa4e6b809ca871db2d7eb1ab6f9fd3f84170aede`, from `https://huggingface.co/giladgd/Qwen3-Reranker-0.6B-GGUF/resolve/main/Qwen3-Reranker-0.6B.Q4_K_M.gguf`.
- Both sizes and hashes were checked against the Hugging Face tree API and against the downloaded files.
- Together they are 706 MB. Both are Apache 2.0. The reranker carries most of the quality, so if EmbeddingGemma 2's weaker English retrieval shows up in our eval, the first fix is a deeper candidate pool for the reranker, not a bigger embedder.
- Runner-up: Qwen3-Embedding-0.6B if retrieval recall turns out to be the bottleneck. gte-reranker-modernbert-base if the reranker's latency is too high on older Macs.

## Vector search

- **Inference, from the numbers above.** Felix's index today is about 2,000 Chrome pages plus 134 notes. With chunking at about 700 characters that is under 20,000 passages. At 768 floats each that is 59 MB in memory, and a flat dot-product scan with Accelerate takes a few milliseconds.
- **Plan.** Keep vectors in one contiguous `[Float]` matrix with a row index, scan with `cblas_sgemv`, and measure. sqlite-vec or an HNSW index only become worth it past a few hundred thousand passages.
- MRL truncation to 256 dimensions would cut memory by two thirds for about one MTEB point. Not needed at this size.

## Hybrid retrieval

- Reciprocal rank fusion (Cormack, Clarke and Buettcher, SIGIR 2009, https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) combines ranked lists without calibrating their scores: the score is the sum over lists of 1 / (k + rank), with k = 60 in the paper.
- FTS5 has BM25 built in through `bm25(table, weights...)`. Lower is better. https://www.sqlite.org/fts5.html#the_bm25_function
- A cross-encoder rerank of the fused top 20 to 30 is the standard second stage. The reranker reads the query and the passage together, so it catches meaning that keyword and vector search miss.

## Measurement

- Precision at 3: of the top three cards shown for a context, how many a person would call useful. It matches the panel, which shows up to three cards per section.
- The eval also counts "should stay empty" contexts. A pipeline that shows anything for those is penalised, since a quiet panel is part of the design.

## Measured after building (2026-11-05)

- **Tested.** On the labelled fixture, the full round 3 pipeline (EmbeddingGemma 2, rank fusion, Qwen3 Reranker, Foundation Models context and judgment) reached precision at 3 of 1.00 and recall at 3 of 0.86, and stayed quiet on all 5 contexts that should show nothing. Round 2 reached 0.94, 0.71 and 4 of 5. The full table is in the [Engine plan](../plans/2026-11-04-engine.md).
- **Tested.** Reranker scores are close to 0 or 1. Relevant items scored 0.55 to 1.00, unrelated ones under 0.1, so its bar sits at 0.15.
- **Tested.** Foundation Models as a judge says yes to near misses that share a subject (a bread-machine review judged the bake log helpful) and rarely says no with confidence above 0.6. It works as a veto at confidence 0.4 or more on borderline cards, not as the main gate.
- **Tested.** A flat scan over 20,000 passages of 768 dimensions with 6 query vectors, plus BM25 and fusion, takes about 110 ms. 60,000 passages take about 370 ms.
- **Tested.** llama.cpp's Metal backend asserts at process exit if models are still loaded (`ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0)`). The app frees models in an exit handler registered after the first load.
