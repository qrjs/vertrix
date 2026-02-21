    .section .data
    .balign 16
    .global vref_start
    .global vref_end
    .global vdata_start
    .global vdata_end

# First: load full 4-element vector (10, 20, 30, 40)
# Then: vfredusum with VL=2 should sum only elements 0-1 (10+20) + acc(100) = 130
# If it incorrectly sums all 4: 10+20+30+40+100 = 200
full_data:
    .float 10.0, 20.0, 30.0, 40.0
acc_val:
    .float 100.0

vdata_start:
dst:
    .float 0.0
vdata_end:

vref_start:
expected:
    .float 130.0
vref_end:

    .section .text
    .global main
main:
    la      a0, full_data
    la      a1, acc_val
    la      a2, dst

    # Load full vector with VL=4 (VLMAX): v1 = {10, 20, 30, 40}
    li      t0, 4
    vsetvli t0, t0, e32, m1, ta, ma
    vle32.v v1, (a0)

    # Load accumulator with VL=1: v2[0] = 100.0
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vle32.v v2, (a1)

    # Reduction with VL=2: should sum only v1[0]+v1[1]+v2[0] = 10+20+100 = 130
    li      t0, 2
    vsetvli t0, t0, e32, m1, ta, ma
    vfredusum.vs v2, v1, v2

    # Store result with VL=1
    li      t1, 1
    vsetvli t1, t1, e32, m1, ta, ma
    vse32.v v2, (a2)

    ret
