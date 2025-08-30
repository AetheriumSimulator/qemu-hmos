#!/usr/bin/env node

// 直接测试NAPI模块
const path = require('path');
const fs = require('fs');

// NAPI模块路径
const napiModulePath = path.join(__dirname, 'entry/src/main/cpp/libqemu_hmos.dylib');

console.log('=== QEMU HarmonyOS NAPI 测试 ===');
console.log('NAPI模块路径:', napiModulePath);
console.log('模块是否存在:', fs.existsSync(napiModulePath));

try {
    // 尝试加载NAPI模块
    const qemuModule = require(napiModulePath);
    
    console.log('\n✅ NAPI模块加载成功');
    console.log('模块导出:', Object.keys(qemuModule));
    
    // 测试版本信息
    if (qemuModule.version) {
        console.log('\n--- 版本信息测试 ---');
        try {
            const version = qemuModule.version();
            console.log('QEMU版本:', version);
        } catch (error) {
            console.error('版本信息获取失败:', error.message);
        }
    }
    
    // 测试JIT支持
    if (qemuModule.enableJit) {
        console.log('\n--- JIT支持测试 ---');
        try {
            const jitSupported = qemuModule.enableJit();
            console.log('JIT支持:', jitSupported);
        } catch (error) {
            console.error('JIT支持检测失败:', error.message);
        }
    }
    
    // 测试KVM支持
    if (qemuModule.kvmSupported) {
        console.log('\n--- KVM支持测试 ---');
        try {
            const kvmSupported = qemuModule.kvmSupported();
            console.log('KVM支持:', kvmSupported);
        } catch (error) {
            console.error('KVM支持检测失败:', error.message);
        }
    }
    
    // 测试VM启动（使用最小配置）
    if (qemuModule.startVm) {
        console.log('\n--- VM启动接口测试 ---');
        const testConfig = {
            vmId: 'test-vm-001',
            name: 'Test VM',
            memory: 512,
            cpu: 1,
            accel: 'tcg',
            display: 'none',
            nographic: true,
            vmDir: '/tmp/qemu-test',
            logPath: '/tmp/qemu-test.log'
        };
        
        try {
            console.log('测试配置:', JSON.stringify(testConfig, null, 2));
            const result = qemuModule.startVm(testConfig);
            console.log('启动结果:', result);
            
            // 如果启动成功，尝试停止
            if (result && qemuModule.stopVm) {
                setTimeout(() => {
                    try {
                        const stopResult = qemuModule.stopVm(testConfig.vmId);
                        console.log('停止结果:', stopResult);
                    } catch (stopError) {
                        console.error('停止VM失败:', stopError.message);
                    }
                }, 2000);
            }
        } catch (error) {
            console.error('VM启动测试失败:', error.message);
        }
    }
    
} catch (error) {
    console.error('\n❌ NAPI模块加载失败:', error.message);
    console.error('错误详情:', error.stack);
    
    // 检查可能的原因
    console.log('\n--- 故障排查 ---');
    console.log('1. 检查模块文件权限');
    try {
        const stats = fs.statSync(napiModulePath);
        console.log('   文件大小:', stats.size, 'bytes');
        console.log('   文件权限:', stats.mode.toString(8));
    } catch (statError) {
        console.error('   无法获取文件信息:', statError.message);
    }
    
    console.log('2. 检查依赖库');
    console.log('   这是一个macOS动态库(.dylib)，需要在macOS环境下运行');
    console.log('   可能需要安装QEMU相关依赖');
}

console.log('\n=== 测试完成 ===');