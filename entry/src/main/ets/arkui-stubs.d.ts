/*
  ArkUI/ArkTS 编辑器类型桩（仅用于消除 IDE/TS 的诊断误报，不参与运行时与实际编译）
  注意：这些声明不会被打包，也不会影响 DevEco/ArkTS 的真实编译产物
*/

// 装饰器（在 TS 视角下需要在作用域中存在）
declare const Entry: any;
declare const Component: any;
declare const State: any;
declare const Builder: any;

// 全局资源访问
declare function $r(id: string): Resource;

// 基本类型占位
declare type Resource = any;

// ArkUI 组件（函数式调用 DSL 在 TS 中作为 any 处理，避免“找不到名称”等误报）
// 注意：不声明 Text/Image，避免与 lib.dom 的全局类型冲突
declare const Stack: any;
declare const Row: any;
declare const Column: any;
declare const Navigation: any;

// 属性/枚举占位
declare const FontWeight: { [k: string]: any };
declare const TextAlign: { [k: string]: any };
declare const HorizontalAlign: { [k: string]: any };
declare const FlexAlign: { [k: string]: any };
declare const VerticalAlign: { [k: string]: any };
declare const ImageRenderMode: { [k: string]: any };
declare const ImageFit: { [k: string]: any };
declare const NavigationTitleMode: { [k: string]: any };

// 三方模块桩（IDE 无法解析 @ohos.display 时提供最小可用定义）
declare module '@ohos.display' {
  const display: {
    getDefaultDisplaySync: () => { width: number; densityDPI?: number }
  };
  export default display;
}