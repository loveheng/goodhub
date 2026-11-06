# Upstream Issue — geniex-android / Qualcomm GenieX (submission-ready, 2026-11-06 修正版)

> 状态：提交就绪（2026-11-06 归因修正版——初稿的「版本退化」定性已被 ngl 对照实验推翻）。
> 目标 = https://github.com/qualcomm/GenieX/issues
> 数据来源：goodhub on-device epic 2026-11-05/06 真机对照 + 版本二分 + ngl 变量隔离（devlog 同日条目），全部为引擎上报 ProfilingData。
> 提交方式：无 GitHub 写权限凭据，由用户在上方 URL 粘贴「Title」+「Body」两段提交。

---

## Title（复制到 issue 标题栏）

```
[llama_cpp / Android SM8750] n_gpu_layers=0 on NPU silently runs every layer on CPU (despite HTP session opening), and that CPU-fallback decode path regressed 26.6 → 1.26 tok/s between v0.3.5 and v0.10.0
```

## Body（复制到 issue 正文）

### Environment

- **Device:** OnePlus Ace 6 — Snapdragon 8 Elite, SM8750, Hexagon v79 (CDSP domain 3), ColorOS / Android 15
- **SDK:** `com.qualcomm.qti:geniex-android` — v0.3.5 / v0.8.0 / v0.9.3 / v0.10.0 (latest on Maven Central)
- **Model:** Qwen3.5-2B Q4_0 GGUF (identical file in every run), `runtime_id = llama_cpp`
- **Params:** prompt ≈ 247 tokens, maxTokens = 128, n_ctx = 4096, nThreads = 0
- **Harness:** ai-hub-apps `geniex_chat` sample `BenchActivity` (`LlmWrapper` + `generateStreamFlow`); identical Kotlin across runs, only the AAR version and `n_gpu_layers` vary

### Summary — two findings

**1. `n_gpu_layers = 0` with `compute_unit = HTP0` silently runs every layer on CPU.** The HTP session still opens (`remote_handle64_open ... libggml-htp-v79.so ... domain 3 (cdsp)` appears in logcat), so downstream code cannot tell from logs that NPU is not actually used. This matches the behavior documented in `notes/run.md` for Windows; on Android it is just as easy to hit and just as invisible.

**2. That CPU-fallback path regressed ~21× between v0.3.5 and v0.10.0** (decode 26.6 → 1.26 tok/s, prefill 534 → 60 tok/s, same device / model / prompt). With the correct `n_gpu_layers = -1`, the HTP path on v0.10.0 is **healthy and faster than v0.3.5** (33.1 vs 29.4 tok/s decode, prefill 590 → 2000 tok/s, TTFT 419 → 125 ms). So this is not a report that v0.10.0 is broken — the HTP path improved — but the CPU fallback became dramatically slower, and the silent fallback makes it easy to mistake for a broken NPU.

### Measurements (engine-reported ProfilingData; same device / model / prompt / n_ctx=4096)

| AAR | n_gpu_layers | Compute path | TTFT | Prefill | Decode |
|---|---|---|---|---|---|
| v0.3.5 | 0 | **CPU fallback** (HTP session open) | 463 ms | 534 tok/s | 26.6 tok/s |
| v0.8.0 | 0 | CPU fallback | 4019 ms | 61.5 tok/s | 6.20 tok/s |
| v0.9.3 | 0 | CPU fallback | 9619 ms | 25.7 tok/s | 2.28 tok/s |
| v0.10.0 | 0 | CPU fallback | 4119 ms | 60 tok/s | **1.26 tok/s** |
| v0.3.5 | **-1** | HTP0 | 419 ms | 590 tok/s | 29.4 tok/s |
| v0.10.0 | **-1** | HTP0 | **125 ms** | **2000 tok/s** | **33.1 tok/s** |

CPU-fallback decode: 26.6 → 6.20 → 2.28 → 1.26 tok/s across v0.3.5 → v0.8.0 → v0.9.3 → v0.10.0. The regression window (v0.3.5 → v0.8.0) overlaps PRs #1367 (thread-count default fix) and #1376 (GGML_OPENMP=OFF, HTP worker pinning) — possibly related to how the CPU fallback schedules threads now.

### Why this matters

- Our production app passed `n_gpu_layers = 0` (copying the sample's default) and got 5.65 tok/s for months; a one-line change to `-1` gives 33 tok/s (6×). The only observable difference from the app's perspective was speed — nothing in the logs or errors distinguishes "NPU session open but running on CPU" from real offload.
- On the CPU-fallback path, v0.10.0 at 1.26 tok/s is unusably slow even as a fallback — below CPU-only llama.cpp on a phone flagship by a wide margin.

### Reproduction

1. Build the `geniex_chat_android` sample, pin `v0.10.0`, load any 2B-class GGUF with `runtime_id = llama_cpp`, `compute_unit = npu`, and **`n_gpu_layers = 0`**. Observe: HTP session opens in logcat, generation succeeds — at ~1.3 tok/s decode.
2. Re-run with `n_gpu_layers = -1`: ~33 tok/s.
3. Repeat step 1 with `v0.3.5`: same silent CPU fallback, but ~26.6 tok/s.

### Expected

1. `n_gpu_layers = 0` with an NPU compute unit should either warn loudly (or fail fast) instead of silently falling back — the open HTP session makes the fallback look like real offload.
2. The CPU fallback itself should not have regressed 21× across versions; v0.3.5's fallback (26.6 tok/s) shows the hardware is capable of it.

### Questions

1. Is `n_gpu_layers = 0` → full-CPU-on-NPU-device the intended semantic, or should it fall back to `-1` / refuse?
2. Could the CPU-fallback regression (26.6 → 1.26 tok/s across v0.3.5 → v0.10.0) be related to the thread-handling changes in the v0.3.5 → v0.8.0 window (#1367, #1376)? Strict HTP worker pinning / OpenMP interplay?
3. Is a config knob available on v0.10.0 to restore v0.3.5-level CPU-fallback performance?

### Attachments (available on request)

- Per-run logcat: adsprpc `remote_handle64_open ... libggml-htp-v79.so ... domain 3` lines (session open during CPU-fallback runs), `PROFILE ttft/promptTime/decodeTime/prefillSpeed/decodingSpeed` for all six runs.
- GGUF sha256 + the sample-app `build.gradle` dependency diff.
