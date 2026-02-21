    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src_data:
    .float 3.0, 5.0
src_acc:
    .float 100.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .float 108.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src_data
    la      a1, src_acc
    la      a2, dst

    # Set VL=2 for the source vector
    li      t0, 2
    vsetvli t0, t0, e32, m1, ta, ma

    # Load source vector (2 elements: 3.0, 5.0)
    vle32.v v1, (a0)

    # Load accumulator (element 0 = 100.0) with VL=1
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vle32.v v2, (a1)

    # Set VL=2 for reduction
    li      t0, 2
    vsetvli t0, t0, e32, m1, ta, ma

    # vfredusum.vs: v2[0] = sum(v1[0..1]) + v2[0] = 3.0 + 5.0 + 100.0 = 108.0
    vfredusum.vs v2, v1, v2

    # Store result with VL=1
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vse32.v v2, (a2)

    ret
