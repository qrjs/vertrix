#include <stdint.h>
#include <riscv_vector.h>
#include "mnist_weights_fp16.h"

extern void spill_cache(uint32_t *start, uint32_t *end);
extern uint8_t vdata_start;
extern uint8_t vdata_end;

volatile int32_t result[1] __attribute__((aligned(4))) = {0};
const int32_t expected[1] __attribute__((aligned(4))) = {7};
asm(".global vref_start\n.set vref_start, expected\n");
asm(".global vref_end\n.set vref_end, expected + 4\n");
asm(".global vdata_start\n.set vdata_start, result\n");
asm(".global vdata_end\n.set vdata_end, result + 4\n");

static uint16_t conv1_out_buf[28*28*3] __attribute__((aligned(64)));
static uint16_t pool1_out_buf[14*14*3] __attribute__((aligned(64)));
static uint16_t conv2_out_buf[14*14*6] __attribute__((aligned(64)));
static uint16_t pool2_out_buf[7*7*6] __attribute__((aligned(64)));
static uint16_t fc1_buf[64] __attribute__((aligned(64)));
static uint16_t fc2_buf[32] __attribute__((aligned(64)));
static uint16_t flatten_buf[294] __attribute__((aligned(64)));
static uint16_t logits_buf[10] __attribute__((aligned(64)));
static uint16_t conv1_wr[27] __attribute__((aligned(64)));
static uint16_t conv2_wr[162] __attribute__((aligned(64)));

static void init_reorder(void) {
    for (int oc = 0; oc < 3; oc++)
        for (int j = 0; j < 9; j++)
            conv1_wr[oc*9+j] = conv1_w_fp16[oc*9+j];
    for (int oc = 0; oc < 6; oc++)
        for (int ic = 0; ic < 3; ic++)
            for (int j = 0; j < 9; j++)
                conv2_wr[oc*27+ic*9+j] = conv2_w_fp16[((oc*3+ic)*3)*3+j];
}

static void im2col(const uint16_t* in, int h, int w, int c, uint16_t* col) {
    int row = 0;
    for (int ky = 0; ky < 3; ky++)
        for (int kx = 0; kx < 3; kx++)
            for (int ic = 0; ic < c; ic++) {
                uint16_t* d = &col[row*h*w];
                for (int oy = 0; oy < h; oy++) {
                    int iy = oy+ky-1;
                    for (int ox = 0; ox < w; ox++) {
                        int ix = ox+kx-1;
                        d[oy*w+ox] = (iy<0||iy>=h||ix<0||ix>=w) ?
                            (uint16_t)0 : in[(iy*w+ix)*c+ic];
                    }
                }
                row++;
            }
}

static void gemm(const uint16_t* A, int M, int K, const uint16_t* B, int N, uint16_t* C) {
    for (int m = 0; m < M; m++) {
        const uint16_t* ar = A+m*K;
        uint16_t* cr = C+m*N;
        size_t n=N; uint16_t* p=cr;
        while (n>0) { size_t vl=__riscv_vsetvl_e16m8(n);
            vuint16m8_t vz = __riscv_vmv_v_x_u16m8(0, vl);
            __riscv_vse16_v_u16m8(p, vz, vl);
            p+=vl; n-=vl; }
        for (int k=0; k<K; k++) {
            uint16_t a_raw = ar[k];
            const uint16_t* br=B+k*N;
            n=N; uint16_t* cp=cr; const uint16_t* bp=br;
            while (n>0) { size_t vl=__riscv_vsetvl_e16m8(n);
                vfloat16m8_t va_splat = __riscv_vreinterpret_v_u16m8_f16m8(
                    __riscv_vmv_v_x_u16m8(a_raw, vl));
                vfloat16m8_t vb = __riscv_vreinterpret_v_u16m8_f16m8(
                    __riscv_vle16_v_u16m8(bp, vl));
                vfloat16m8_t vc = __riscv_vreinterpret_v_u16m8_f16m8(
                    __riscv_vle16_v_u16m8(cp, vl));
                vc = __riscv_vfmacc_vv_f16m8(vc, va_splat, vb, vl);
                __riscv_vse16_v_u16m8(cp,
                    __riscv_vreinterpret_v_f16m8_u16m8(vc), vl);
                bp+=vl; cp+=vl; n-=vl; }
        }
    }
}

static void conv3x3(const uint16_t* in, int h, int w, int c,
                    const uint16_t* wt, int oc, uint16_t* out) {
    uint16_t col[9*c*h*w] __attribute__((aligned(64)));
    uint16_t gr[oc*h*w] __attribute__((aligned(64)));
    im2col(in,h,w,c,col);
    gemm(wt,oc,9*c,col,h*w,gr);
    for (int oy=0;oy<h;oy++)
        for (int ox=0;ox<w;ox++) {
            int si=oy*w+ox;
            for (int o=0;o<oc;o++) out[si*oc+o]=gr[o*h*w+si];
        }
}

static void do_relu(uint16_t* d, int sz) {
    size_t n=sz; uint16_t* p=d;
    while (n>0) { size_t vl=__riscv_vsetvl_e16m8(n);
        vfloat16m8_t v = __riscv_vreinterpret_v_u16m8_f16m8(
            __riscv_vle16_v_u16m8(p, vl));
        vfloat16m8_t vz = __riscv_vreinterpret_v_u16m8_f16m8(
            __riscv_vmv_v_x_u16m8(0, vl));
        v = __riscv_vfmax_vv_f16m8(v, vz, vl);
        __riscv_vse16_v_u16m8(p,
            __riscv_vreinterpret_v_f16m8_u16m8(v), vl);
        p+=vl; n-=vl; }
}

static void pool2x2(const uint16_t* in, int h, int w, int c, uint16_t* out) {
    int oh=h/2, ow=w/2;
    for (int oy=0;oy<oh;oy++)
        for (int ox=0;ox<ow;ox++) {
            int iy=oy*2,ix=ox*2;
            const uint16_t *p00=&in[(iy*w+ix)*c], *p01=&in[(iy*w+ix+1)*c];
            const uint16_t *p10=&in[((iy+1)*w+ix)*c], *p11=&in[((iy+1)*w+ix+1)*c];
            uint16_t* op=&out[(oy*ow+ox)*c];
            size_t n=c;
            while (n>0) { size_t vl=__riscv_vsetvl_e16m1(n);
                vfloat16m1_t a=__riscv_vfmax_vv_f16m1(
                    __riscv_vreinterpret_v_u16m1_f16m1(__riscv_vle16_v_u16m1(p00,vl)),
                    __riscv_vreinterpret_v_u16m1_f16m1(__riscv_vle16_v_u16m1(p01,vl)),vl);
                vfloat16m1_t b=__riscv_vfmax_vv_f16m1(
                    __riscv_vreinterpret_v_u16m1_f16m1(__riscv_vle16_v_u16m1(p10,vl)),
                    __riscv_vreinterpret_v_u16m1_f16m1(__riscv_vle16_v_u16m1(p11,vl)),vl);
                __riscv_vse16_v_u16m1(op,
                    __riscv_vreinterpret_v_f16m1_u16m1(__riscv_vfmax_vv_f16m1(a,b,vl)),vl);
                p00+=vl;p01+=vl;p10+=vl;p11+=vl;op+=vl;n-=vl; }
        }
}

static void do_fc(const uint16_t* in, int inf, const uint16_t* wt, int outf, uint16_t* out) {
    for (int o=0;o<outf;o++) {
        const uint16_t* ip=in;
        const uint16_t* wp=wt+o*inf;
        size_t n=inf;
        vfloat16m1_t vs = __riscv_vreinterpret_v_u16m1_f16m1(
            __riscv_vmv_v_x_u16m1(0, 1));
        while (n>0) { size_t vl=__riscv_vsetvl_e16m4(n);
            vfloat16m4_t vi = __riscv_vreinterpret_v_u16m4_f16m4(
                __riscv_vle16_v_u16m4(ip,vl));
            vfloat16m4_t vw = __riscv_vreinterpret_v_u16m4_f16m4(
                __riscv_vle16_v_u16m4(wp,vl));
            vfloat16m4_t vm = __riscv_vfmul_vv_f16m4(vi,vw,vl);
            vs = __riscv_vfredusum_vs_f16m4_f16m1(vm,vs,vl);
            ip+=vl;wp+=vl;n-=vl; }
        vuint16m1_t vr = __riscv_vreinterpret_v_f16m1_u16m1(vs);
        out[o] = __riscv_vmv_x_s_u16m1_u16(vr);
    }
}

static void hwc2chw(const uint16_t* hwc, int h, int w, int c, uint16_t* chw) {
    for (int ch=0;ch<c;ch++)
        for (int y=0;y<h;y++)
            for (int x=0;x<w;x++)
                chw[ch*h*w+y*w+x]=hwc[(y*w+x)*c+ch];
}

int main(void) {
    init_reorder();
    conv3x3((const uint16_t*)input_fp16_data,28,28,1,conv1_wr,3,conv1_out_buf);
    do_relu(conv1_out_buf,28*28*3);
    pool2x2(conv1_out_buf,28,28,3,pool1_out_buf);
    conv3x3(pool1_out_buf,14,14,3,conv2_wr,6,conv2_out_buf);
    do_relu(conv2_out_buf,14*14*6);
    pool2x2(conv2_out_buf,14,14,6,pool2_out_buf);
    hwc2chw(pool2_out_buf,7,7,6,flatten_buf);
    do_fc(flatten_buf,294,fc1_w_fp16,64,fc1_buf);
    do_relu(fc1_buf,64);
    do_fc(fc1_buf,64,fc2_w_fp16,32,fc2_buf);
    do_relu(fc2_buf,32);
    do_fc(fc2_buf,32,fc3_w_fp16,10,logits_buf);

    int mi=0; uint16_t mv=logits_buf[0];
    for (int i=1;i<10;i++) {
        uint16_t vi=logits_buf[i];
        int16_t sa=(int16_t)mv, sb=(int16_t)vi;
        if ((sa>=0 && sb>=0 && sb>sa) || (sa<0 && sb>=0) ||
            (sa<0 && sb<0 && sb<sa)) { mv=vi; mi=i; }
    }
    result[0]=mi;
    spill_cache((uint32_t*)&vdata_start,(uint32_t*)&vdata_end);
    return 0;
}
