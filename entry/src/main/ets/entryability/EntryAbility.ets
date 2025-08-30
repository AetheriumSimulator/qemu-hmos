import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: object): void {
    console.info('[EntryAbility] onCreate');
  }

  onDestroy(): void {
    console.info('[EntryAbility] onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[EntryAbility] onWindowStageCreate');
    
    windowStage.loadContent('pages/Index', (err, data) => {
      if (err.code) {
        console.error(`[EntryAbility] Failed to load the content. Code: ${err.code}, message: ${err.message}`);
        return;
      }
      console.info('[EntryAbility] Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    console.info('[EntryAbility] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[EntryAbility] onForeground');
  }

  onBackground(): void {
    console.info('[EntryAbility] onBackground');
  }
}