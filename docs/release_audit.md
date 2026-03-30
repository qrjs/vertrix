# Release Audit

## Current Status

- Regression entrypoint is now `make -C test`.
- The default test target runs each suite once instead of re-running the same
  suite through directory aliases and per-test expansion.
- The following validation command passed:

```sh
make -C test lsu alu mul sld elem csr kernel misc fp
```

- Integer and FP kernel regressions currently pass, including:
  - `kernel/mnist_infer`
  - `kernel/mnist_infer_fp32`
  - `kernel/mnist_infer_fp32_fc3zero`
  - `kernel/mnist_infer_fp32_norelu`
  - `kernel/mnist_infer_matunit`

## Remaining Technical Gaps

### Fetch / Integration

- Simulation and integration are still effectively Ibex-only.
  - `sim/Makefile` rejects non-Ibex main cores.
  - multiple integration scripts still assume Ibex-specific structure.
- There are still open integration TODOs in the imported Ibex front-end and
  decode path, especially around debug/illegal-instruction interaction.

### Floating-Point

- FP support is usable for the currently checked-in tests, but not complete.
- `rtl/vproc_decoder.sv` still marks several widening FP operations as TODO or
  requiring fpnew changes:
  - `vfwadd`
  - `vfwsub`
  - `vfwadd.w`
  - `vfwsub.w`
- FP conversion decode currently hardcodes rounding mode in several paths.
- `rtl/vproc_fpu.sv` still contains configuration and masking TODOs that should
  be resolved before claiming full FP support.

### Vector / Reduction Semantics

- `rtl/vproc_elem.sv` still notes masked reductions as unsupported.
- Several pipeline/control comments indicate incomplete handling of exceptional
  cases and auxiliary counters.

## External-Origin Risk

This repository cannot currently be represented as wholly self-authored.

### Explicit Branding / Attribution Still Present

- Top-level `README.md` still identifies the project as `Vicuna`.
- Documentation under `docs/01_user/` is still written as Vicuna user
  documentation.
- Many source files still carry upstream copyright and SPDX headers.

### Imported / Derived Code That Must Not Be Misrepresented

- `ibex/` submodule and `rtl/ibex_*` files are clearly Ibex-derived.
- `vendor/lowrisc_ip/` dependencies are external lowRISC IP.
- `rtl/cvfpu/` and `rtl/cvfpu/src/common_cells/` are clearly third-party code.
- `rtl/cvfpu/vendor/opene906/` is third-party vendor code.
- `.gitmodules` still references upstream repositories, including `ibex`,
  `cv32e40x`, and `hide/vicuna2_core`.
- `vproc_*` naming, Vicuna references, and TU Wien copyright headers are still
  present throughout the tree.

## Release Recommendation

Do not try to remove or obscure origin information. The defensible options are:

1. Release as a derived work with preserved attribution and correct licenses.
2. Replace sensitive modules through clean-room rewrites and only then remove
   the old derived implementations.

## Rewrite Priority

### Must Rewrite Before Claiming "Our Own Core"

1. Top-level branding and user documentation.
2. Any module derived directly from Ibex front-end / control / CSR logic.
3. Any module copied from Vicuna wholesale and still carrying Vicuna-specific
   structure or comments.
4. The FP wrapper/decode layer if you want to claim original FP integration.

### Can Stay as Third-Party with Proper Attribution

1. Ibex as a submodule or clearly attributed imported block.
2. CVFPU / fpnew and common_cells.
3. Other vendor IP under `vendor/` or `rtl/cvfpu/vendor/`.

## Suggested Next Steps

1. Decide whether the public release is a derived-work release or a
   rewrite-first release.
2. If derived-work release:
   - keep upstream headers
   - add a `THIRD_PARTY_NOTICES` file
   - document which directories are imported or modified
3. If rewrite-first release:
   - start with fetch/integration, FP decode/wrapper, and top-level docs
   - keep imported code isolated until replacements are complete
   - validate each replacement against the current regression baseline
