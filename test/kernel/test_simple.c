// 极简测试 - 验证基本的内存写入和dump功能
#include <stdint.h>

extern void spill_cache(uint32_t *start, uint32_t *end);

// 使用非零初始值，放在.data段
volatile int test_data[5] __attribute__((aligned(64))) = {0xAAAAAAAA, 0xAAAAAAAA, 0xAAAAAAAA, 0xAAAAAAAA, 0xAAAAAAAA};
const int ref_data[5] __attribute__((aligned(64))) = {7, 2, 1, 0, 4};

asm(".global vref_start\n.set vref_start, ref_data\n");
asm(".global vref_end\n.set vref_end, ref_data + 20\n");
asm(".global vdata_start\n.set vdata_start, test_data\n");
asm(".global vdata_end\n.set vdata_end, test_data + 20\n");

int main(void) {
    // 简单赋值
    test_data[0] = 7;
    test_data[1] = 2;
    test_data[2] = 1;
    test_data[3] = 0;
    test_data[4] = 4;
    
    // 刷新缓存
    extern uint8_t vdata_start;
    extern uint8_t vdata_end;
    spill_cache((uint32_t *)&vdata_start, (uint32_t *)&vdata_end);
    
    return 0;
}
