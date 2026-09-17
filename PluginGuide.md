# DeskKit 组件开发

每个组件是一个 `.deskkit` 文件夹，包含 `widget.json` 和 `render.js`。在应用左下角点击“新建”即可开始。组件位于 `~/Library/Application Support/DeskKit/Plugins/`，外部编辑器的修改每两秒自动检查并加载。

## 数据源

`widget.json` 必填字段：`id`（唯一且不能修改）、`name`、`description`、`symbol`（SF Symbol）、`version: 1`、`refreshSeconds`、`source`、`script: "render.js"`、`defaultEnabled`、`menuBar`、`widget`。

source.kind 可以是：

- `system`：内置网速、CPU、内存、磁盘采集。`source.interface` 可指定此组件的网卡（例如 `en0`），留空自动选择；各组件独立采样。
- `codex`：查询已有 Codex 登录账号的额度。`source.executable` 可指定此组件的 Codex 可执行文件绝对路径，留空自动查找。
- `static`：把 source.value 对象传给脚本。
- `http`：配置 url；默认解析 JSON，设置 format 为 text 则传入 `{text: "响应正文"}`。
- `command`：配置 executable 的绝对路径，以及 arguments 字符串数组；在组件包目录执行。默认输出 JSON，也可设置 format 为 text。命令以当前用户身份执行，仅启用你信任的组件。

系统主程序执行数据采集，布局脚本没有文件、网络或命令执行接口。

## 布局脚本

定义 `function render(data, context)`，返回一个对象：

```javascript
function render(data, context) {
  const card = {type:'column', spacing:10, children:[
    {type:'text', text:data.title || '我的组件', size:22, weight:'semibold'},
    {type:'progress', value:67, max:100, color:'accent'}
  ]};
  return {menuBar:'67%', panel:card, widget:card};
}
```

- `menuBar`：单行菜单栏文字。`menuBarLines` 可返回最多两行短文字（例如下载、上传速度）。
- `menuBarRows`：最多两行，每行为 `{left:'↓ 128',right:'KB/s'}`；左列固定左对齐，右列固定右对齐，优先于 `menuBarLines`。`menuBarWidth` 指定固定菜单项宽度（48–180 pt，默认 72），不随数据变化。
- `panel`：菜单栏弹窗布局。
- `widget`：小号桌面布局。`medium`、`large` 可分别提供中号、大号布局，省略时回退。
- context.now：毫秒时间戳。context.locale：语言。

布局节点：`column`、`row`（children、spacing、alignment）；`text`（text、size、weight、color）；`metric`（label、text、symbol）；`progress`（value、max、color）；`symbol`（symbol、size）；`divider`；`spacer`；`chart`（values、size）；`link`（text、url）。

颜色支持 primary、secondary、accent、green、red、orange、blue。桌面组件在系统着色或玻璃模式下自动使用系统前景色。请勿用一张不透明背景截图代替布局。

脚本每次运行上限 3 秒，超过后终止独立脚本进程并自动恢复。布局深度最多 12，所有布局合计最多 256 节点；脚本 256 KB，数据 1 MB。`render` 需要同步返回可序列化对象。

自启动开关位于侧栏底部。网卡、可执行文件等数据源选项位于各组件的“配置”中，随组件文件保存。

## 在应用中编辑

在“脚本”和“配置”中按 Command-F 可打开编辑器内的搜索栏，输入关键字会即时高亮匹配内容。Command-G 查找下一个，Command-Shift-G 查找上一个。只读和编辑状态均可搜索。

“脚本”和“配置”默认只读，提供语法高亮、行号和代码滚动。点击“编辑”开始修改；“保存”会写入文件、让正式组件生效并退出编辑，Command-S 也可保存。“预览”单独使用当前草稿与最近采集的数据渲染右上角的效果，不保存文件，也不更新正式菜单栏或桌面卡片。编辑时可点击“取消编辑”，确认“放弃修改”后返回只读状态；选择“继续编辑”则保留草稿。“自动换行”按钮在只读和编辑时均可使用，并记住选择；它只调整显示，不会改变文件内容或原始行号。

右上角的缩略预览保持静止，仅在打开组件、手动预览或保存后取得新布局时更新。同时启用菜单栏和小组件时可切换预览位置；小组件提供大、中、小三种尺寸。取消编辑会恢复保存版本的预览。预览失败会保留上次效果，并在预览区域提示错误。

预览使用独立的脚本进程和内存中的采集数据；草稿不会触发新的网络请求或命令执行。静态数据源可直接使用配置草稿中的 value。其他数据源首次使用或配置变化后，需要先保存数据源配置并完成一次正常采集，才能使用对应数据预览。

切换组件、切换视图、关闭窗口或退出应用时，如有未保存修改，会询问保存、不保存或取消。保存失败会保留编辑内容；检测到外部文件变化时也不会直接覆盖。

点击组件图标可从分类图标库中选择图标。顶部的“菜单栏”和“小组件”复选框直接决定显示位置；两个都不勾选时停用组件。

## 删除组件

在组件详情页点击“删除”，或在侧栏右键选择“删除组件…”，确认后会把整个组件包移到废纸篓。菜单栏项目和桌面组件选项同步移除；已放在桌面的卡片需要重新选择内容或手动移除。内置组件删除后不会在重启时自动安装。

误删时可从废纸篓放回组件文件夹，或恢复文件后重新导入，再手动启用。

## 更新与错误

菜单栏更新不受 WidgetKit 预算约束；桌面组件由系统调度，采集间隔不等于桌面刷新间隔。失败时保留最后一次成功数据并标记为缓存。原生小组件显示成功采集时间。停用组件会停止采集，并从组件选择列表移除。

编辑配置中的默认显示位置只用于首次安装。已有组件的启用状态、菜单栏和桌面开关以应用界面为准。
