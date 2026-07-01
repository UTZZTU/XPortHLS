# HiSparse U280 Profile Case

This case profiles the public HiSparse repository as a real XRT/Vitis/HBM project.

The case is intentionally profile-only. It validates that XPortHLS can repeatedly identify:

- source runtime: XRT
- source board: Alveo U280
- toolchain: Vitis 2020.2
- shell/platform string: `xilinx_u280_xdma_201920_3`
- HBM/DDR memory mappings
- Vitis build files and targets
- connectivity directives
- HLS kernel candidates
- HLS interface pragmas
- stream and SLR facts
- ApplicationIR v2 construction
- expected profile-only gaps

It does not generate an AVED project.
