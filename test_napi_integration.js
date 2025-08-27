// QEMU HarmonyOS NAPI 集成测试脚本
// 用于验证 Native 模块的基本功能

// 模拟 HarmonyOS NAPI 环境
const mockNAPI = {
  // 模拟 NAPI 函数调用
  callNativeFunction: function(moduleName, functionName, ...args) {
    console.log(`调用 Native 函数: ${moduleName}.${functionName}(${args.join(', ')})`);
    
    // 模拟不同函数的返回值
    switch(functionName) {
      case 'GetVersion':
        return 'QEMU HarmonyOS Wrapper 1.0.0';
      case 'EnableJit':
        return true;
      case 'KvmSupported':
        return false; // 在 HarmonyOS 上通常不支持 KVM
      case 'StartVm':
        console.log('启动虚拟机...');
        return true;
      case 'StopVm':
        console.log('停止虚拟机...');
        return true;
      default:
        return null;
    }
  }
};

// 测试函数
function testQemuNAPIIntegration() {
  console.log('=== QEMU HarmonyOS NAPI 集成测试 ===\n');
  
  // 测试版本获取
  console.log('1. 测试版本信息:');
  const version = mockNAPI.callNativeFunction('qemu_hmos', 'GetVersion');
  console.log(`   版本: ${version}\n`);
  
  // 测试 JIT 支持
  console.log('2. 测试 JIT 支持:');
  const jitEnabled = mockNAPI.callNativeFunction('qemu_hmos', 'EnableJit');
  console.log(`   JIT 启用: ${jitEnabled}\n`);
  
  // 测试 KVM 支持
  console.log('3. 测试 KVM 支持:');
  const kvmSupported = mockNAPI.callNativeFunction('qemu_hmos', 'KvmSupported');
  console.log(`   KVM 支持: ${kvmSupported}\n`);
  
  // 测试虚拟机启动
  console.log('4. 测试虚拟机启动:');
  const startResult = mockNAPI.callNativeFunction('qemu_hmos', 'StartVm');
  console.log(`   启动结果: ${startResult}\n`);
  
  // 模拟运行时间
  console.log('5. 模拟虚拟机运行 (3秒)...');
  setTimeout(() => {
    // 测试虚拟机停止
    console.log('\n6. 测试虚拟机停止:');
    const stopResult = mockNAPI.callNativeFunction('qemu_hmos', 'StopVm');
    console.log(`   停止结果: ${stopResult}\n`);
    
    console.log('=== 测试完成 ===');
  }, 3000);
}

// 运行测试
if (typeof module !== 'undefined' && module.exports) {
  // Node.js 环境
  module.exports = { testQemuNAPIIntegration, mockNAPI };
} else {
  // 浏览器或其他环境
  testQemuNAPIIntegration();
}

// 如果直接运行此脚本
if (require.main === module) {
  testQemuNAPIIntegration();
}