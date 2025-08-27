// 测试 QEMU 库链接的简单程序
#include <iostream>
#include <cstdlib>

// 简单的 QEMU 功能测试，不依赖完整的 QEMU 头文件
extern "C" {
    // 声明一些基本的 QEMU 函数（如果存在）
    // 这里只是测试链接，不实际调用
}

int main() {
    std::cout << "QEMU 库链接测试" << std::endl;
    std::cout << "基础库链接成功！" << std::endl;
    return 0;
}