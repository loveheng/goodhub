# Upstream Issue — geniex-android / Qualcomm GenieX (submission-ready)

> 状态：提交就绪（2026-11-06）。目标 = https://github.com/qualcomm/GenieX/issues
> 数据来源：goodhub on-device epic 2026-11-05/06 真机对照 + 版本二分（devlog 同日条目），全部为引擎上报 ProfilingData。
> 提交方式：无 GitHub 写权限凭据，由用户在上方 URL 粘贴「Title」+「Body」两段提交。

---

## Title（复制到 issue 标题栏）

```
[llama_cpp / NPU+GPU] SM8750: decode 26.6 → 1.26 tok/s (21x) regression between v0.3.5 and v0.8.0, persists through v0.10.0 — and below the v0.8.0 figure reported in #1584
```

## Body（复制到 issue 正文）

### Environment

- **Device:** OnePlus Ace 6 — Snapdragon 8 Elite, **SM8750**, Hexagon v79 (CDSP domain 3), ColorOS / Android 15
- **SDK:** `com.qualcomm.qti:geniex-android` — bisected across **v0.3.5 / v0.8.0 / v0.9.3 / v0.10.0** (latest on Maven Central, 2026-10-29)
- **Model:** Qwen3.5-2B Q4_0 GGUF (single identical file across every run), `runtime_id = llama_cpp`
- **Params:** prompt ≈ 247 tokens, maxTokens = 128, n_ctx = 4096, n_gpu_layers = 0, nThreads = 0
- **Harness:** ai-hub-apps `geniex_chat` sample `BenchActivity` (`LlmWrapper` + `generateStreamFlow`); identical Kotlin across versions, only the AAR dependency is changed between runs
- **Compute unit verified on-HW via logcat:** `compute_unit = HTP0`, `libggml-htp-v79.so` loaded from the APK via adsprpc (cdsp session established). The NPU numbers are genuine HTP execution, not a CPU fallback.

### Summary

On SM8750 the `llama_cpp` backend decode throughput collapses from ~26.6 tok/s (v0.3.5) to ~1.26 tok/s (v0.10.0) — a **21× regression** — for the same GGUF, prompt, and calling code. Bisection: v0.8.0 = 6.20, v0.9.3 = 2.28, v0.10.0 = 1.26 tok/s (NPU); GPU OpenCL 29.6 → 1.47 tok/s. So the regression is **introduced between v0.3.5 and v0.8.0** and persists, roughly unchanged, through v0.10.0. Both compute units regress; prefill regresses ~9× as well.

### Measurements (engine-reported ProfilingData; same device / model / prompt / n_ctx=4096)

| Harness | AAR | Compute unit | TTFT | Prefill | Decode |
|---|---|---|---|---|---|
| sample app | v0.3.5 | NPU (HTP0) | 463 ms | 534 tok/s | **26.6 tok/s** |
| sample app | v0.3.5 | GPU (OpenCL) | 1510 ms | 164 tok/s | **29.6 tok/s** |
| sample app | **v0.8.0** | NPU (HTP0) | 4019 ms | 61.5 tok/s | **6.20 tok/s** |
| sample app | **v0.9.3** | NPU (HTP0) | 9619 ms | 25.7 tok/s | **2.28 tok/s** |
| sample app | **v0.9.3** | GPU (OpenCL) | 4529 ms | 54.6 tok/s | **1.47 tok/s** |
| sample app | **v0.10.0** | NPU (HTP0) | 4119 ms | 60 tok/s | **1.26 tok/s** |
| sample app | **v0.10.0** | GPU (OpenCL) | 4330 ms | 57 tok/s | **3.16 tok/s** |
| production app (tuned LlmCreateInput) | v0.10.0 | NPU (HTP0) | 4554 ms | ~54 tok/s | 5.65 tok/s |
| production app (tuned LlmCreateInput) | v0.10.0 | GPU (OpenCL) | 5393 ms | ~55 tok/s | 5.77 tok/s |
| Qualcomm AI Hub published (8 Elite) | — | NPU | — | 593 tok/s | 22.6 tok/s |

Decode worst case: NPU 26.6 → 1.26 tok/s (21×, at v0.10.0); GPU 29.6 → 1.47 tok/s (20×, at v0.9.3). Prefill ~9× on both units.

### Variables excluded (measured, not assumed)

- **AAR self-contained:** v0.10.0 ships the full native set (QNN + `libggml-{cpu,opencl,hexagon}` + `libggml-htp-v{73,75,79,81,85}.so`); install docs require nothing beyond the AAR. No separate runtime package is missing.
- **HTP actually engaged:** logcat shows `compute_unit = HTP0` + successful adsprpc load of `libggml-htp-v79.so` during the 1.26 tok/s run — not a silent CPU fallback.
- **n_ctx:** re-ran 4096 vs 8192 — halving the context window does not recover speed.
- **Plugin layout (cf. #1507):** every run below opens the HTP session and emits valid tokens, so the flattened-layout failure mode from #1507 is **not** the cause here.
- **App-side config:** reproduces in the untouched sample harness, so downstream app configuration is not the variable.

### Related / prior art

- **#1584** reports v0.8.0 `llama_cpp` on the **same SoC (SM8750, Z Fold 7)** at **15.59 tok/s decode for Qwen3.5-4B Q4_0** (author rebuilt only `libgeniex_plugin_llama_cpp.so`). Our v0.8.0 figure is **6.20 tok/s for a smaller 2B model** — i.e. well below a reported 4B number. Before concluding a pure version regression I want to rule out a harness/model/config artifact on my side.
- **#1507:** `-100201` can also be a plugin-layout issue; noted as excluded above.

### Reproduction

1. Build the `geniex_chat_android` sample from `qualcomm/ai-hub-apps`, pin `com.qualcomm.qti:geniex-android:0.3.5`, run a 2B-class GGUF on any 8 Elite (SM8750) device with `compute_unit = npu` and `gpu` — record decode speed (baseline ≈ 26–29 tok/s).
2. Change only the dependency to `v0.8.0` / `v0.9.3` / `v0.10.0`, adapting for the API breaks (`model_name` removed from `LlmCreateInput`; `enable_thinking`/`verbose` removed from `ModelConfig`; `generateStreamFlow` signature), and re-run unchanged otherwise.
3. Observe decode drop to ~1–6 tok/s and prefill to ~25–60 tok/s.

### Expected

v0.10.0 should match or exceed the AI Hub published figure for the same SoC (≈ 22.6 tok/s decode / ≈ 593 tok/s prefill), which v0.3.5 already approaches on-device.

### Questions

1. Is this a known `llama_cpp` backend regression between v0.3.5 and v0.8.0 (kernel scheduling, quantized-matmul path, or HTP skel change)?
2. Is there a configuration knob on v0.10.0 (sampler/session flags, `ModelConfig` fields) known to restore v0.3.5-level performance?
3. Given #1584's higher numbers on the same SoC — is our harness missing a fast-path flag? What exact `geniex-bench` invocation / device config produced 15.59 tok/s for 4B on SM8750, so we can align our harness?
4. If confirmed a regression, is a v0.10.x / v0.11 patch release planned?

### Attachments (available on request)

- Per-run logcat: `[extract] compute_unit = HTP0`, adsprpc skel-load lines, and `PROFILE ttft/promptTime/decodeTime/prefillSpeed/decodingSpeed` for all eight runs.
- GGUF sha256 + the sample-app `build.gradle` dependency diff across versions.
