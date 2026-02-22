# ADR-0032 - Step E1 agent base image upgraded to CUDA devel + professional toolchain

Date: 2026-02-22

## Context

The previous shared agent base image (`agent-cli-base`) was intentionally minimal (`bash`, `tmux`, `git`, `curl`), which forced repetitive bootstrap work inside agent sessions for professional development workflows (C/C++, Python, Node, Go, Rust, CUDA).

`PLAN.md` step E1 now requires:

1. an NVIDIA CUDA devel base compatible with DGX Spark (ARM64),
2. a professional default toolchain available out-of-the-box,
3. unchanged confinement expectations (non-root runtime, no docker.sock, hardened compose settings).

## Decision

1. Switch `deployments/images/agent-cli-base/Dockerfile` base image to:
   - `nvidia/cuda:13.0.1-devel-ubuntu24.04@sha256:7d2f6a8c2071d911524f95061a0db363e24d27aa51ec831fcccf9e76eb72bc92`.
2. Preinstall development toolchains and utilities in the shared base image:
   - core/runtime: `bash`, `tmux`, `git`, `git-lfs`, `curl`, `ca-certificates`, `openssh-client`, `rsync`,
   - general dev: `build-essential`, `cmake`, `ninja-build`, `pkg-config`, `python3` + `venv` + `pip`, `nodejs`, `npm`, `golang-go`, `rustc`, `cargo`,
   - C/C++ quality/debug: `gdb`, `gdbserver`, `valgrind`, `clang`, `clangd`, `lld`, `lldb`, `clang-format`, `clang-tidy`, `cppcheck`, `ccache`, `bear`, `meson`, `autoconf`, `automake`, `libtool`,
   - productivity: `ripgrep`, `fd-find`, `jq`, `shellcheck`, `shfmt`, `direnv`,
   - common native dev libs: `libc6-dev`, `libssl-dev`, `zlib1g-dev`, `libffi-dev`, `libbz2-dev`, `libreadline-dev`, `libsqlite3-dev`.
3. Keep the existing runtime contract:
   - non-root default user (`agent`),
   - persistent tmux-compatible entrypoint,
   - no additional container privileges introduced.
4. Extend `tests/E1_image_build.sh` to validate:
   - key tool presence including `nvcc`,
   - smoke compilation for C/C++ and CUDA.

## Consequences

- Agent sessions become immediately usable for professional multi-language development on DGX-class hosts.
- Image build time/size increases significantly versus the previous minimal base.
- E1b override support remains available for operators who want a smaller or custom base image while preserving hardening controls.
