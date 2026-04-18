# Third-Party And Derived-Work Notices

This repository is a mixed-origin hardware project. It should be represented as
a derived-work tree with preserved attribution.

## Derived Or Imported Components

- `rtl/ibex_*`, `hide/ibex_*`, and Ibex integration paths are Ibex-derived
  logic or related imported code
- `vendor/lowrisc_ip/` contains third-party lowRISC IP and DV collateral
- `rtl/cvfpu/` contains third-party floating-point sources, including
  `common_cells` and vendor subtrees
- `.gitmodules` references external upstream repositories used by this tree
- many `vproc_*` modules retain Vicuna-origin structure, naming, or headers

## Local Extensions In This Tree

- floating-point decode and wrapper integration around the existing vector core
- FP32 MNIST software flow, exported weights, samples, and kernel regressions
- experimental matrix and outer-product datapaths under `rtl/`
- local regression and validation infrastructure updates under `test/`

## Release Guidance

- Do not remove upstream copyright or SPDX headers from imported files.
- Do not claim the repository is wholly self-authored unless imported and
  derived implementations have been replaced.
- If releasing publicly, keep this notice file and describe which directories
  are imported, modified, or original.

## Practical Rule Of Thumb

Use the following language when describing the project:

> A derived Vicuna-class RISC-V vector accelerator repository with Ibex-based
> integration, third-party floating-point/vendor IP, and local FP32/ML
> extensions.
