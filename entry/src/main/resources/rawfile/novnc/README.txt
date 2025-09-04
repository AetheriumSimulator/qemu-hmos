Place your noVNC bundle here.

Expected file:
- novnc.min.js  (a standalone bundle that exposes window.RFB)

Build noVNC from https://github.com/novnc/noVNC (or use a pre-built rfb.min.js + app logic) and concatenate into a single file.

This app will load rawfile/novnc/novnc.min.js into a WebView and connect to ws://127.0.0.1:5901 (QEMU started with `-display vnc=:1,websocket=on`).

