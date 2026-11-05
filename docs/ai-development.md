# Working with AI on ThermoBar

ThermoBar is an AI-assisted development example: a small native utility whose hardware access and measurement semantics need verification beyond generated code that merely compiles.

The source review started from commit `8e0c075`. It examined security exposure, ownership, sampling and failure modes. Two hypotheses were reproduced against the original implementation using simulated readings:

- Missing timestamps compared as `NaN != NaN` released stale battery power during a source transition.
- A sensor unavailable during initial discovery remained absent after its readings recovered.

The follow-up implementation separates the sampler actor from main-actor UI state and adds committed regression tests. It also fixes CPU baselines after pauses, GPU chart bounds and model-specific dashboard claims. Power-decoding fixtures exercise signed and wrapped current values through the actual C parser, rather than reimplementing its calculation in a test.

AI assistance was used for the review, implementation and test authoring. Changes are checked by compilation, deterministic tests, static analysis and a separate live hardware smoke test. The repository keeps the constraints visible: private macOS interfaces, heuristic sensor grouping, approximate power telemetry and an ad-hoc development build. None of these checks certifies measurement accuracy or replaces manual hardware and UI testing.

The intended demonstration is the complete loop: identify a concrete failure, reproduce it, fix the implementation, preserve the regression test and document what the evidence does and does not establish. CI makes the repeatable checks visible to a reviewer.
