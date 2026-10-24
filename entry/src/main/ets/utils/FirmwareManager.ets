import fs from '@ohos.file.fs'
import common from '@ohos.app.ability.common'
import hilog from '@ohos.hilog'

const FIRMWARE_CODE_FILENAME: string = 'edk2-aarch64-code.fd'
const FIRMWARE_VARS_FILENAME: string = 'edk2-arm-vars.fd'
const PFLASH_BYTES: number = 64 * 1024 * 1024

export class FirmwareManager {
  /** Install the current bundled image separately from legacy/custom firmware. */
  static async ensureUefi(ctx: common.UIAbilityContext): Promise<string | null> {
    let temporaryDirectory = ''
    try {
      const checksum = await ctx.resourceManager.getRawFileContent(`${FIRMWARE_CODE_FILENAME}.sha256`)
      let digest = ''
      for (let index = 0; index < checksum.length; index++) {
        digest += String.fromCharCode(checksum[index])
      }
      digest = digest.trim()
      if (!/^[a-f0-9]{64}$/.test(digest)) {
        throw new Error('Invalid bundled UEFI identity')
      }
      const directory = `${ctx.filesDir}/aetherium-uefi-${digest}`
      const target = `${directory}/${FIRMWARE_CODE_FILENAME}`
      if (await fs.access(target)) {
        await FirmwareManager.requirePflash(target)
        return target
      }

      const code = await ctx.resourceManager.getRawFileContent(FIRMWARE_CODE_FILENAME)
      if (code.length !== PFLASH_BYTES) {
        throw new Error('Bundled aarch64 UEFI must be exactly 64 MiB')
      }
      // Publish a complete directory atomically. A failed write never becomes a
      // usable cache entry, and an existing nonempty directory is not replaced.
      temporaryDirectory = await fs.mkdtemp(`${ctx.filesDir}/.aetherium-uefi-XXXXXX`)
      await FirmwareManager.writeImage(`${temporaryDirectory}/${FIRMWARE_CODE_FILENAME}`, code)

      // VARS is optional. Existing per-VM NVRAM is preserved by the native layer.
      let vars: Uint8Array | null = null
      try {
        vars = await ctx.resourceManager.getRawFileContent(FIRMWARE_VARS_FILENAME)
      } catch (_) {
        hilog.info(0x0000, 'FIRMWARE', 'No bundled VARS template; using existing per-VM NVRAM if present')
      }
      if (vars !== null) {
        if (vars.length !== PFLASH_BYTES) {
          throw new Error('Bundled aarch64 VARS must be exactly 64 MiB')
        }
        await FirmwareManager.writeImage(`${temporaryDirectory}/${FIRMWARE_VARS_FILENAME}`, vars)
      }
      try {
        await fs.rename(temporaryDirectory, directory)
        temporaryDirectory = ''
      } catch (error) {
        // Another request may have finished the same immutable bundle first.
        if (!(await fs.access(target))) {
          throw new Error((error as Error).message)
        }
      }
      await FirmwareManager.requirePflash(target)
      return target
    } catch (error) {
      hilog.error(0x0000, 'FIRMWARE', 'UEFI preparation failed: %{public}s', (error as Error).message)
      return null
    } finally {
      if (temporaryDirectory.length > 0) {
        // Only remove this invocation's private staging files, never user data.
        for (const filename of [FIRMWARE_CODE_FILENAME, FIRMWARE_VARS_FILENAME]) {
          try { await fs.unlink(`${temporaryDirectory}/${filename}`) } catch (_) { /* absent */ }
        }
        try { await fs.rmdir(temporaryDirectory) } catch (_) { /* harmless abandoned staging directory */ }
      }
    }
  }

  private static async requirePflash(path: string): Promise<void> {
    const stat = await fs.stat(path)
    if (!stat.isFile() || stat.size !== PFLASH_BYTES) {
      throw new Error(`Invalid aarch64 pflash image: ${path}`)
    }
  }

  private static async writeImage(path: string, content: Uint8Array): Promise<void> {
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE)
    try {
      let offset = 0
      while (offset < content.length) {
        const end = Math.min(offset + 1024 * 1024, content.length)
        const chunk = content.buffer.slice(content.byteOffset + offset, content.byteOffset + end) as ArrayBuffer
        const written = await fs.write(file.fd, chunk)
        if (written <= 0 || written > chunk.byteLength) {
          throw new Error('UEFI write did not make progress')
        }
        offset += written
      }
      await fs.fsync(file.fd)
    } finally {
      await fs.close(file)
    }
    await FirmwareManager.requirePflash(path)
  }
}
