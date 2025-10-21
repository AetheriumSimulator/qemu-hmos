import { FlutterContainer } from '@ohos/flutter_ohos'
import { MainPage } from './MainPage'

@Component
export struct FlutterHost {
  build() {
    Column() {
      // Flutter容器
      FlutterContainer({
        name: 'flutter_app',
        src: 'lib/main.dart',
        params: {
          // 传递给Flutter的参数
        }
      })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}

