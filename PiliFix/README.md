# PiliFix — 让 PiliPlus 在 iOS 17 上能启动

## 症状

PiliPlus（Flutter 应用，bundle id `com.example.piliplus`）在某些 iOS 17 设备（实测 iPhone 13 mini / iPhone14,4 / iOS 17.1.1）
上无论哪个版本、不管越不越狱、不管怎么签名安装，都**卡在启动图（绿色 P）不动**：
不崩溃、不报错，CPU 也不高。同一份 ipa 在别人的机器上正常。

## 原因

PiliPlus 的 `Runner.app/Frameworks/App.framework/flutter_assets/NativeAssetsManifest.json`
用**相对路径**登记它用 Dart native assets 加载的两个 FFI 原生库：

```json
"native-assets": {
  "ios_arm64": {
    "package:objective_c/objective_c.dylib": ["absolute", "objective_c.framework/objective_c"],
    "package:cnativeapi/cnativeapi.dart":   ["absolute", "cnativeapi.framework/cnativeapi"]
  }
}
```

iOS 应用进程的当前工作目录是 `/`，不是 App 包目录。所以 Dart 通过 `dart:ffi` 去
`dlopen("objective_c.framework/objective_c")` 时，dyld 从 `/` 开始找，必然失败：

```
dlopen(objective_c.framework/objective_c, 0x0001): tried:
  'objective_c.framework/objective_c' (no such file),
  '/private/preboot/Cryptexes/OSobjective_c.framework/objective_c' (no such file)
```

（`Mpv.framework/Mpv` 这种也一样是相对路径，只是它恰好命中 dyld 的框架回退搜索，所以能加载成功；
`objective_c` / `cnativeapi` 命中不了。）

而 `lib/main.dart` 的启动顺序是：

```dart
ScaledWidgetsFlutterBinding.ensureInitialized();
MediaKit.ensureInitialized();   // 这一步能过，libmpv 加载成功
await _initAppPath();           // getApplicationSupportDirectory()，这版 path_provider 走 objective_c FFI
await GStorage.init();          // Hive
...
runApp(const MyApp());
```

`objective_c` 加载不进来 → `_initAppPath()` 的 FFI 绑定用不了 → `main()` 走不到 `runApp()`，
Flutter 永远画不出第一帧，屏幕上就一直停在系统 LaunchScreen 那张启动图上。

## 怎么自己确认是不是这个问题

1. 看 App 数据目录里有没有 `Library/Application Support/hive/`：正常启动会建出来，卡启动图时不存在。
2. 抓 `dlopen`（需要越狱 + 一个注入探针）：会看到上面那条 `objective_c.framework/objective_c` 失败，
   之后再没有任何 Dart 发起的 dlopen。
3. 线程栈：主线程在 `CFRunLoopRunSpecific` 空转，`io.flutter.1.raster` 一直等消息（从没收到过一帧），
   Dart 侧一条平台通道调用都没有。

## 修复原理

注入 App 进程，钩住 `dlopen`：遇到相对路径先在 `<App 包>/` 和 `<App 包>/Frameworks/` 里找，
找到就用绝对路径加载；找不到就原样交给 dyld。

- **不修改 App 的任何文件**（不改二进制、不改签名、不改数据），因此更新/重装 PiliPlus 之后照样生效；
  路径在运行时用 `NSBundle.mainBundle` 现算，容器 UUID 变了也没影响。
- 只影响「相对路径、且当前目录下不存在」的 `dlopen`，对其它调用是空转。

## 安装

```
# 在软件源 https://xuezhixiatongsheng.github.io/ios-/ 里安装：
com.xuezhixiatongsheng.pilifix
```

支持 roothide（iphoneos-arm64e）与 rootless（iphoneos-arm64）。
安装后杀掉并重开 PiliPlus 即可；启动后 App 的 `Documents/.pilifix.status` 会写入 `PiliFix build=<id>`。

## 局限

- 依赖越狱注入（ElleKit / TweakInject）：**不越狱时这个 tweak 不会加载**，PiliPlus 会再次卡启动图。
- 如果哪天 PiliPlus 自己把 manifest 改成了绝对路径，这个 tweak 就变成空转，可以卸掉。

## 源码

- `src/PiliFix.m`：全部逻辑（约 130 行，只依赖 Foundation + ElleKit 的 `MSHookFunction`）
- `src/PiliFix.plist`：注入过滤器，按可执行文件名 `Runner` / `PiliPlus`
- `build.sh`：构建脚本（clang 编译成 dylib → `ldid -S` 签名 → `dpkg-deb -b` 打包）

本目录的 `build.sh` 是原工程的构建脚本，依赖 APELIN_* 环境变量；自己构建时把变量换成本机路径即可，
核心就是一条 `clang -arch arm64e -dynamiclib -fobjc-arc -O2 -o PiliFix.dylib src/PiliFix.m -framework Foundation`
加 `ldid -S PiliFix.dylib`，把 `PiliFix.dylib` 和 `PiliFix.plist` 放进
`/usr/lib/TweakInject/`（rootless 为 `/var/jb/usr/lib/TweakInject/`）。
