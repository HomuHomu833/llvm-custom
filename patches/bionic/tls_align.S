/*
 * Bionic allocates an 8-word TCB starting at the thread pointer, so on arm and
 * arm64 an executable's PT_TLS must be aligned to 8 words (32 / 64 bytes) for
 * its segment to clear those slots. Otherwise the loader aborts at startup:
 *
 * error: "<prog>": executable's TLS segment is underaligned: alignment is 8
 * (skew 0), needs to be at least 64 for ARM64 Bionic
 *
 * (bionic/libc/bionic/bionic_elf_tls.cpp, reserve_exe_segment_and_tcb).
 *
 * Bionic's crtbegin.c emits exactly this overalignment, but only under
 * __ANDROID_API__ >= 29, and our bionic tools target older API levels - so supply it
 * ourselves. Linked into every bionic executable (see scripts/build.sh); a no-op
 * object on the architectures/API levels that don't need it.
 *
 * The global symbol is passed to the linker with -u so --gc-sections keeps
 * .tdata (old assemblers reject the .reloc crtbegin uses for this).
 */
#if __ANDROID_API__ < 29
#if defined(__arm__)
.section .tdata, "awT", %progbits
.p2align 5
.globl __bionic_tls_align_anchor
.type __bionic_tls_align_anchor, %tls_object
__bionic_tls_align_anchor:
#elif defined(__aarch64__)
.section .tdata, "awT", @progbits
.p2align 6
.globl __bionic_tls_align_anchor
.type __bionic_tls_align_anchor, %tls_object
__bionic_tls_align_anchor:
#endif
#endif

