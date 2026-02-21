    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

src:
    .float 1.0, 2.0, 3.0, 4.0

# Initial scalar value in element 0 of vs1
scalar_init:
    .float 10.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    # vfredusum.vs: sum(src) + scalar_init[0] = (1+2+3+4) + 10 = 20.0
    .float 20.0
vref_end:

    .section .text
    .global main
main:
    la      a0, src
    la      a1, scalar_init
    la      a2, dst

    # Load source vector (4 elements)
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v1, (a0)

    # Load scalar initial value (1 element into v2)
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vle32.v v2, (a1)

    # Perform reduction: v3[0] = sum(v1[0:3]) + v2[0]
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vfredusum.vs v3, v1, v2

    # Store result (element 0 only)
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vse32.v v3, (a2)

    ret
