// 系统状态：将原生采集器提供的数据转换成菜单栏和桌面卡片布局。
// 数据源、网卡和采集间隔在 widget.json 中设置：source.kind、source.interface、refreshSeconds。
// 脚本只负责计算与展示；网速采样、CPU 统计等由 DeskKit 完成。

// 网速的输入单位是字节/秒（B/s），不是比特/秒（bps）。
// 按 1024 进位：KB/s 取整数，MB/s、GB/s 保留一位小数。
// 首次采样、切换网卡或数据无效时显示「—」，避免把未知速度显示成 0。
function rate(value) {
  if (value === null || !Number.isFinite(value)) return '—';
  if (value >= 1073741824) return (value / 1073741824).toFixed(1) + ' GB/s';
  if (value >= 1048576) return (value / 1048576).toFixed(1) + ' MB/s';
  if (value >= 1024) return Math.round(value / 1024) + ' KB/s';
  return Math.round(value) + ' B/s';
}
// render 是 DeskKit 调用的入口，必须同步返回布局对象。
// data.interface：当前网卡名；download / upload：下载、上传速度，单位 B/s。
// data.cpu：CPU 占用百分比，可能为 null；memoryUsed / memoryTotal：内存字节数。
// data.diskTotal / diskAvailable：用户主目录所在卷的总容量、可用容量，单位字节。
// data.history：最近最多 45 个有效下载速度样本，从旧到新排列，不一定覆盖整整 45 秒。
// context 提供 now（毫秒时间戳）和 locale；这个组件目前不使用它们。
function render(data, context) {
  // 布局是描述原生视图的对象：column 纵向排列，metric 展示「名称 + 数值 + 可选图标」。
  // 调整 spacing 可改变项目间距；symbol 使用 SF Symbols 名称。
  const column = children => ({type:'column', spacing:10, children:children});
  const metric = (label, text, symbol) => ({type:'metric',label:label,text:text,symbol:symbol});
  // 容量统一换算成 GiB（1024³ 字节），保留一位小数。
  const gib = n => (n/1073741824).toFixed(1);
  // 磁盘已用比例 = 1 - 可用 / 总量；总量未知时用 null 表示，而不是显示 0%。
  // 可用容量包含系统认为可清理的空间，因此这里的占用口径可能与其他工具不同。
  const diskPercent = data.diskTotal > 0 ? Math.round((1-data.diskAvailable/data.diskTotal)*100) : null;
  // 内存比例来自采集器提供的已用/总量；分母无效时沿用 0 的回退值。
  // CPU 的 null 单独显示为「—」，有数据时四舍五入成整数百分比。
  const memoryPercent = data.memoryTotal > 0 ? data.memoryUsed/data.memoryTotal*100 : 0;
  const cpu = data.cpu === null ? '—' : Math.round(data.cpu) + '%';
  // 点击菜单栏网速后展开的内容；此布局也复用于中号桌面组件。
  // children 数组的顺序就是显示顺序，可在这里增删指标或调整排列。
  const panel = column([
    {type:'text',text:data.interface || '未连接',size:11,color:'secondary'},
    metric('下载',rate(data.download),'arrow.down'),
    metric('上传',rate(data.upload),'arrow.up'),
    // 下载速度趋势图；size 为图表高度，缺少历史数据时传空数组。
    {type:'chart',values:data.history || [],color:'accent',size:36},
    {type:'divider'},
    metric('CPU',cpu,'cpu'),
    metric('内存',gib(data.memoryUsed)+' / '+gib(data.memoryTotal)+' GiB','memorychip'),
    // 内存进度条以 100 为满格；达到 85% 改用橙色，可在这里修改提醒阈值。
    {type:'progress',value:memoryPercent,max:100,color:memoryPercent>=85?'orange':'accent',label:'内存占用'},
    metric('磁盘',diskPercent===null?'—':'已用 '+diskPercent+'%','internaldrive'),
    {type:'text',text:data.diskTotal>0?'可用 '+gib(data.diskAvailable)+' GiB · 含可清理空间':'磁盘数据暂不可用',size:10,color:'secondary'}
  ]);
  // 小号桌面卡片：只保留 CPU、内存、磁盘三项，减少有限空间里的信息密度。
  // 原生桌面组件的实际刷新时间由 macOS 调度，采集间隔不等于桌面刷新间隔。
  const card = column([
    {type:'text',text:'系统状态',size:13,weight:'semibold'},
    metric('CPU',cpu),
    metric('内存',Math.round(memoryPercent)+'%'),
    metric('磁盘',diskPercent===null?'—':diskPercent+'%')
  ]);
  // 将「↓ 128 KB/s」拆成两列：left =「↓ 128」，right =「KB/s」。
  // DeskKit 固定左列左对齐、右列右对齐，数字位数和单位变化时不会挤动整个菜单项。
  // 无有效速度时只有「↓ —」，没有空格可拆，右列保持空字符串。
  function menuRow(arrow, value) {
    const formatted = rate(value);
    const separator = formatted.lastIndexOf(' ');
    return separator < 0
      ? {left:arrow+' '+formatted,right:''}
      : {left:arrow+' '+formatted.slice(0,separator),right:formatted.slice(separator+1)};
  }
  // 输出不同显示位置的布局；是否启用菜单栏/桌面由应用里的两个复选框决定。
  return {
    // 两行依次为下载和上传。menuBarWidth 是固定宽度（pt），需要更多空间可调整 72。
    menuBarRows:[menuRow('↓',data.download),menuRow('↑',data.upload)],menuBarWidth:72,
    // 保留整行文字作为回退；提供 menuBarRows 时优先使用上面的左右分列布局。
    menuBarLines:['↓ '+rate(data.download),'↑ '+rate(data.upload)],
    // panel：菜单栏展开页；widget：小号桌面卡片；medium：中号桌面卡片。
    panel:panel,widget:card,medium:panel
  };
}
