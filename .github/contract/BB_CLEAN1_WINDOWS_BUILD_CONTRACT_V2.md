# BB CLEAN1 — WINDOWS BUILD CONTRACT V2

Date: 2026-09-16

## 1. Authority and scope

This is a narrow successor to `BB_CLEAN1_WINDOWS_BUILD_CONTRACT_V1.md`. V1 remains immutable historical evidence.

V2 exists only because the authenticated V1 execution reached S7 after proving source, Windows build and package, then the frozen launcher failed while reading the Recorder process exit code.

V2 does **not** authorize any C++ change, Recorder change, fixture change, UMA policy change, gameplay/graphics/save patch change, new reservation protocol, merge to `Shadlix`, or Bloodborne execution.

The frozen identities remain:

- baseline commit `03d62ad22438344f1dcd38c5b5e44f660b564b92`
- baseline tree `a71d05341ad927c1c3fb7ff56b04a2b52aa2beb1`
- parent R3-SAVEFIX-S1 SHA256 `92ee02584cae06cc4feace76dcbfdaadcca225e3a005b1038246850fa154c485`
- READY4 ZIP SHA256 `0b709de7e6c588b76786d8b648d5f669563c0bf45df5ec44a63db56f869e795f`
- PATCHFIX1 ZIP SHA256 `13144512830870296d297ebbe194dd8a2d30d9c8eb57358654b67392a7824308`
- selected integration SHA256 `9e998761b9aefdf7649f001a0ffaf875755733cf4b3885d63a8aec349fd34efa`
- frozen harness commit `184e040de310f54024866adc6d5aa540d495a5fa`
- frozen launcher PS SHA256 `eaaec92a072abbda4119edae6880667ef3cbd43d48fa784c805c555fb1b2d0ae`
- frozen launcher CMD SHA256 `22752522a5c39813ceb66d4099a716cbf226b17e0bf4e03b29d898b995e53530`

## 2. Accepted V1 evidence

Authoritative failing run: GitHub Actions `35116669854`, head `2032be0bb05d4fe9f73e004b23276d91db605a4a`.

Accepted states from its diagnostics:

- `SOURCE_VALIDATED=YES`
- `WINDOWS_BUILD_PASS=YES`
- `PACKAGE_PASS=YES`
- `SMOKE_PASS=NOT_RUN`
- `FINAL_STAGE=S7`
- `FIRST_FAILURE=STOP_S7_LAUNCHER exit=1`
- runtime ZIP SHA256 `56769a61251f1b0d83c15a96cbd5c7e4f5740016c2234f081d867f0c3f1473f2`

The launcher log reports `Recorder exited with code ` with an empty value after `WaitForExit(15000)` completed.

## 3. Root cause classification

The frozen PowerShell launcher starts the Recorder with:

`Start-Process ... -PassThru -NoNewWindow`

and later reads the returned process object's `.ExitCode`.

PowerShell issue #5421 documents the Windows behavior where a process object created with `Start-Process -PassThru -NoNewWindow` can expose a null/empty `ExitCode` even after process termination. Its documented workaround is to read/cache the process handle before waiting. The issue explicitly includes Windows PowerShell 5.1 in the reproduced environment.

References:

- https://github.com/PowerShell/PowerShell/issues/5421
- https://github.com/PowerShell/PowerShell/issues/20400

The V1 evidence therefore does not establish a non-zero Recorder exit. It establishes that the frozen launcher could not obtain a numeric Recorder exit code in the selected Windows PowerShell path.

## 4. Authorized launcher amendment

V2 MUST first authenticate the original frozen launcher bytes. Only after that check may it substitute the V2 launcher in the isolated package input.

The V2 PowerShell launcher differs from V1 only as follows:

1. Immediately after starting the Recorder, evaluate `$rec.Handle` and discard the value. This caches the native process handle before any wait, matching the documented workaround.
2. Keep the producer invocation semantics unchanged (`-PassThru -Wait -NoNewWindow`). Add an explicit null check for `$producer.ExitCode`; do not turn an unavailable code into success.
3. After Recorder completion, store `.ExitCode` in `$recRc`, reject null explicitly, then compare the numeric value with zero.
4. Do not change readiness timeout, Recorder completion timeout, mapping, output directory, environment, producer target, process kill behavior or capture-status checks.
5. Do not change `run_blackbox.cmd`.

Authorized V2 launcher PS SHA256:

`71d6d3f20ddf81881d0d3a9c7eb25dbd6ca783a16bfe319f0cf218d49ce15ac3`

## 5. Executor amendments

The V2 executor is generated deterministically from the V1 executor and must fail if any expected replacement cardinality is not exactly one.

Authorized executor-only changes:

- use a fresh `bb-clean1-contract-v2` work directory;
- fold the already accepted V1 Qt `qt.conf` normalization into the effective contract rather than patching it ad hoc in the workflow;
- after authenticating the original frozen launchers, replace only the PS launcher with the versioned V2 launcher and verify its SHA256;
- preserve all files created under the S7 smoke directory into diagnostics in a best-effort failure-evidence subtree even if S7 stops before the normal success-copy block.

The failure-evidence copy must never modify `Runtime`, `Reopened` or the ZIP.

## 6. Required execution

Run the full S0→S8 chain in a new GitHub Actions Windows workspace. Do not reuse the V1 package as a V2 deliverable because the launcher bytes change and therefore S5/S6 package identity must be regenerated.

No retry-until-green is allowed. A V2 S7 failure is preserved and classified from its first causal error.

A runnable artifact may be uploaded only if the entire V2 contract reaches S8 with `SMOKE_PASS=YES` and the tested ZIP hash remains unchanged after smoke.

Regardless of build result:

- `CAPTURE_VALIDATED=NO`
- `CAPTURE_READINESS=NOT_READY`
- `RUNTIME_TEST_ALLOWED=false`

No Bloodborne execution is authorized by this contract.
