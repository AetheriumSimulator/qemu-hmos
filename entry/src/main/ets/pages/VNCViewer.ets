import router from '@ohos.router'
import common from '@ohos.app.ability.common'
import webview from '@ohos.web.webview'
import fs from '@ohos.file.fs'

// 简易的 noVNC 加载器：从 rawfile/novnc/ 读取 novnc.min.js 并嵌入到 WebView
// 若未放置该文件，则显示提示文案。

interface VMInfoParam { name?: string; vncPort?: number }
interface VncRouteParams { vmInfo?: VMInfoParam }

@Entry
@Component
struct VNCViewer {
  @State vmName: string = ''
  @State vncPort: number = 5901
  private webCtrl: webview.WebviewController = new webview.WebviewController()

  aboutToAppear() {
    const params = router.getParams()
    if (params && typeof params === 'object') {
      const p = params as VncRouteParams
      if (p.vmInfo) {
        if (typeof p.vmInfo.name === 'string') this.vmName = p.vmInfo.name
        if (typeof p.vmInfo.vncPort === 'number') this.vncPort = p.vmInfo.vncPort
      }
    }
    this.loadNoVnc()
  }

  private goBack() { router.back() }

  private async loadNoVnc() {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const rm = ctx.resourceManager
      let novncJs = ''
      let novncEsm = ''
      try {
        const jsBytes = await rm.getRawFileContent('novnc/novnc.min.js')
        novncJs = new TextDecoder('utf-8').decode(jsBytes)
      } catch (_) {
        novncJs = ''
      }
      if (!novncJs) {
        try {
          const esmBytes = await rm.getRawFileContent('novnc/novnc.esm.js')
          novncEsm = new TextDecoder('utf-8').decode(esmBytes)
        } catch (_e) {
          novncEsm = ''
        }
      }

      const escEsm = novncEsm ? JSON.stringify(novncEsm) : ''
      const html = `<!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>html,body,#root{height:100%;margin:0;padding:0;background:#000;color:#fff;font-family:system-ui,-apple-system}#toolbar{position:fixed;top:8px;left:8px;right:8px;display:flex;gap:8px;align-items:center}#screen{position:absolute;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center}canvas{max-width:100%;max-height:100%;}</style>
      </head>
      <body>
        <div id="toolbar">
          <span>noVNC</span>
          <span id="status">Connecting ws://127.0.0.1:${this.vncPort}</span>
        </div>
        <div id="screen"><canvas id="vncCanvas"></canvas></div>
        ${novncJs ? `<script>${novncJs}</script>` : ''}
        <script>
        (async function(){
          try{
            if(!window.RFB && ${escEsm ? 'true' : 'false'}){
              const code = ${escEsm || "''"};
              const url = URL.createObjectURL(new Blob([code], {type:'text/javascript'}));
              const mod = await import(url);
              window.RFB = mod && mod.default ? mod.default : undefined;
            }
            var RFB = window.RFB;
            if(!RFB){
              document.getElementById('status').innerText = '缺少 noVNC 资源，请将 novnc.min.js 或 novnc.esm.js 放到 rawfile/novnc/ 目录';
              return;
            }
            var target = document.getElementById('vncCanvas');
            var rfb = new RFB(target, 'ws://127.0.0.1:${this.vncPort}');
            rfb.viewOnly = false; rfb.scaleViewport = true; rfb.background = '#000';
            rfb.addEventListener('connect', function(){ document.getElementById('status').innerText='已连接';});
            rfb.addEventListener('disconnect', function(){ document.getElementById('status').innerText='已断开';});
          }catch(e){ document.getElementById('status').innerText='加载失败: '+e; }
        })();
        </script>
      </body>
      </html>`

      // 优先使用 loadData（无需额外文件路径）
      // @ts-ignore
      if (typeof this.webCtrl.loadData === 'function') {
        // @ts-ignore
        this.webCtrl.loadData(html, 'text/html', 'utf-8')
      } else if (typeof (this.webCtrl as any).loadDataWithBaseUrl === 'function') {
        (this.webCtrl as any).loadDataWithBaseUrl('about:blank', html, 'text/html', 'utf-8', '')
      }
    } catch (e) {
      // ignore
    }
  }

  build() {
    Column() {
      Row() {
        Button('返回').onClick(() => this.goBack())
        Text(this.vmName).fontSize(16).fontWeight(FontWeight.Medium).margin({ left: 8 })
      }.width('100%').padding(12)

      Web({ src: '' })
        .controller(this.webCtrl)
        .javaScriptAccess(true)
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
