# PiliFix — 让 PiliPlus 在 iOS 17 上能启动

PiliPlus 在很多 iOS 17 设备上会**永久卡在启动图（绿色 P）**：不崩溃、不报错、CPU 不高，换版本、重装、越不越狱都一样。这个仓库只做一件事——修好它。

安装：在软件源 `https://xuezhixiatongsheng.github.io/ios-/` 里装 `com.xuezhixiatongsheng.pilifix`（支持 roothide 与 rootless）。

## 原因

PiliPlus 是 Flutter 应用，它的 `Runner.app/Frameworks/App.framework/flutter_assets/NativeAssetsManifest.json`
用**相对路径**登记两个 Dart native-assets 的 FFI 原生库：

```json
"native-assets": {
  "ios_arm64": {
    "package:objective_c/objective_c.dylib": ["absolute", "objective_c.framework/objective_c"],
    "package:cnativeapi/cnativeapi.dart":   ["absolute", "cnativeapi.framework/cnativeapi"]
  }
}
```

iOS 应用进程的当前工作目录是 `/`，不是 App 包目录。所以 Dart 通过 `dart:ffi` 执行
`dlopen("objective_c.framework/objective_c")` 时，dyld 从 `/` 开始找，必然失败：

```
dlopen(objective_c.framework/objective_c, 0x0001): tried:
  'objective_c.framework/objective_c' (no such file),
  '/private/preboot/Cryptexes/OSobjective_c.framework/objective_c' (no such file)
```

而 `lib/main.dart` 的启动顺序是：

```dart
ScaledWidgetsFlutterBinding.ensureInitialized();
MediaKit.ensureInitialized();   // 能过，libmpv 加载成功
await _initAppPath();           // getApplicationSupportDirectory()，这版 path_provider 走 objective_c FFI
await GStorage.init();          // Hive
...
runApp(const MyApp());
```

`objective_c` 没加载进来 → `_initAppPath()` 的 FFI 绑定用不了 → `main()` 走不到 `runApp()`，
Flutter 永远画不出第一帧，屏幕上就一直停在系统 LaunchScreen 那张启动图上。

## 修复原理

注入 App 进程，钩住 `dlopen`：遇到相对路径先在 `<App 包>/` 和 `<App 包>/Frameworks/` 里找，
找到就用绝对路径加载，找不到就原样交给 dyld。

- **不修改 App 的任何文件**（不改二进制、不改签名、不改数据），所以更新/重装 PiliPlus 之后照样生效；
  路径运行时用 `NSBundle.mainBundle` 现算，容器 UUID 变了也不影响。
- 只影响「相对路径、且当前目录下不存在」的 `dlopen`，其余调用空转。

## 自己确认是不是这个问题

1. 看 App 数据目录有没有 `Library/Application Support/hive/`：正常启动会建出来，卡启动图时不存在。
2. 有越狱的话抓 `dlopen`（注入一个探针即可）：会看到上面那条 `objective_c.framework/objective_c` 失败，
   之后再没有任何 Dart 发起的 `dlopen`。
3. 线程栈：主线程在 `CFRunLoopRunSpecific` 空转，`io.flutter.1.raster` 一直等消息（没收到过一帧），
   Dart 侧一条平台通道调用都没有。

## 局限

- 依赖越狱注入（ElleKit / TweakInject）：**不越狱时这个 tweak 不会加载**，PiliPlus 会再次卡启动图。
- 如果哪天 PiliPlus 自己把 manifest 改成绝对路径，这个 tweak 就变成空转，可以卸掉。

## 源码与构建

- `src/PiliFix.m`：全部逻辑（约 130 行，只依赖 Foundation + ElleKit 的 `MSHookFunction`）
- `src/PiliFix.plist`：注入过滤器，按可执行文件名 `Runner` / `PiliPlus`
- `build.sh`：`clang -dynamiclib` 编译 → `ldid -S` 签名 → `dpkg-deb -b` 打包（脚本里用 APELIN_* 变量指路径，自己构建时换成本机路径即可）

产物放到 `/usr/lib/TweakInject/`（rootless 为 `/var/jb/usr/lib/TweakInject/`）。
安装后杀掉并重开 PiliPlus；启动成功后 App 的 `Documents/.pilifix.status` 会写入 `PiliFix build=<id>`。

## 注意
仓库里**不要再提交任何版本号不同的重复 .deb**，也不要手改 `Packages*`／`Release`，交给工作流生成。
