import http from '@ohos.net.http';
import data_preferences from '@ohos.data.preferences';

interface DownloadTaskInfo {
  id: string;
  url: string;
  path: string;
  downloaded: number;
  total: number;
  speed: number;
  eta: number;
  status: 'queued' | 'downloading' | 'completed' | 'error';
}

const PREFS_NAME: string = 'downloads';

class DownloadManager {
  private tasks: Map<string, DownloadTaskInfo> = new Map();
  private nextId: number = 0;
  private pref?: data_preferences.Preferences;
  private listeners: ((tasks: DownloadTaskInfo[]) => void)[] = [];
  private context: any;

  constructor(context: any) {
    this.context = context;
  }

  async init() {
    this.pref = await data_preferences.getPreferences(this.context, PREFS_NAME);
    const raw = await this.pref.get('tasks', '[]');
    const list: DownloadTaskInfo[] = JSON.parse(raw as string);
    list.forEach(t => {
      this.tasks.set(t.id, t);
      const parsed = Number(t.id);
      if (!Number.isNaN(parsed)) {
        this.nextId = Math.max(this.nextId, parsed + 1);
      }
    });
    this.emit();
  }

  onUpdate(cb: (tasks: DownloadTaskInfo[]) => void) {
    this.listeners.push(cb);
  }

  getTasks(): DownloadTaskInfo[] {
    return Array.from(this.tasks.values());
  }

  private emit() {
    const arr = this.getTasks();
    this.listeners.forEach(fn => fn(arr));
  }

  private async persist() {
    if (!this.pref) {
      return;
    }
    await this.pref.put('tasks', JSON.stringify(this.getTasks()));
    await this.pref.flush();
  }

  async enqueue(url: string, path: string) {
    const id = `${this.nextId++}`;
    const task: DownloadTaskInfo = {
      id,
      url,
      path,
      downloaded: 0,
      total: 0,
      speed: 0,
      eta: 0,
      status: 'queued'
    };
    this.tasks.set(id, task);
    await this.persist();
    this.emit();
    this.start(task);
  }

  private start(task: DownloadTaskInfo) {
    task.status = 'downloading';
    const downloadTask = http.createDownloadTask(task.url, {
      filePath: task.path,
      enableRange: true
    });
    const startTime = Date.now();
    downloadTask.on('progress', (received: number, total: number) => {
      task.downloaded = received;
      task.total = total;
      const elapsed = (Date.now() - startTime) / 1000;
      task.speed = elapsed > 0 ? received / elapsed : 0;
      const remaining = total - received;
      task.eta = task.speed > 0 ? remaining / task.speed : 0;
      this.emit();
      this.persist();
    });
    downloadTask.on('complete', () => {
      task.status = 'completed';
      task.speed = 0;
      task.eta = 0;
      this.emit();
      this.persist();
    });
    downloadTask.on('error', (_err: any) => {
      task.status = 'error';
      this.emit();
      this.persist();
    });
    downloadTask.start();
  }
}

export { DownloadManager, DownloadTaskInfo };
