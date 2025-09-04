import fs from '@ohos.file.fs'
import common from '@ohos.app.ability.common'

// 固件目标落地路径（App files 目录内）
const TARGET_PATH: string = '/data/storage/el2/base/haps/entry/files/edk2-aarch64-code.fd'

export class FirmwareManager {
  /**
   * 确保 UEFI 固件存在：优先从 rawfile 复制到 files 目录
   * @param ctx 可选 UIAbility 上下文；若提供可直接读取 rawfile
   */
  static async ensureUefi(ctx?: common.UIAbilityContext | common.Context): Promise<boolean> {
    try {
      if (await FirmwareManager.exists(TARGET_PATH)) {
        return true
      }

      // 若缺失，尝试从 rawfile 复制
      const rm = (ctx as any)?.resourceManager
      if (!rm || typeof rm.getRawFileContent !== 'function') {
        console.error('[Firmware] 无法获取 resourceManager，无法从 rawfile 复制固件')
        return false
      }

      let content: Uint8Array
      try {
        // rawfile 下直接以文件名访问
        content = await rm.getRawFileContent('edk2-aarch64-code.fd')
      } catch (e) {
        console.error('[Firmware] 读取 rawfile 失败: ' + (e as Error).message)
        return false
      }

      try {
        // 写入目标路径（覆盖写入以防半成品）
        const file = await fs.open(TARGET_PATH, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
        await fs.write(file.fd, content)
        await fs.close(file)
        return true
      } catch (e) {
        console.error('[Firmware] 写入固件失败: ' + (e as Error).message)
        return false
      }
    } catch (e) {
      console.error('[Firmware] ensureUefi 异常: ' + (e as Error).message)
      return false
    }
  }

  private static async exists(path: string): Promise<boolean> {
    try {
      await fs.access(path)
      return true
    } catch (_) {
      return false
    }
  }
}
