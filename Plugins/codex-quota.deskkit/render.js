// Codex 额度：展示各额度周期的剩余百分比、进度条和下一次重置时间。
// 数据源是 widget.json 的 source.kind = "codex"；DeskKit 负责读取当前登录账号的额度。
// 可执行文件位置在 source.executable 配置，采集间隔在 refreshSeconds 配置。
// 本脚本只把数据转换成原生布局，不负责登录或发起额度请求。

// data.primary / secondary：最多两个额度周期，缺失时可能为 null。
// 每个周期包含 remainingPercent（剩余百分比）、windowDurationMins（周期分钟数）、
// resetsAt（Unix 秒时间戳）。remainingPercent 已由采集端根据已用比例换算，无需再次相减。
// context 提供 now（毫秒时间戳）和 locale；当前脚本不使用它们。
function render(data, context) {
  // 只留下实际返回的周期对象，不假定 primary 一定是 5 小时或 secondary 一定是周额度。
  // 两个都没有时抛出错误，由 DeskKit 展示错误状态并保留已有的成功数据。
  const windows = [data.primary,data.secondary].filter(w => w !== null && typeof w === 'object');
  if (!windows.length) throw new Error('没有额度数据，请检查 Codex 登录状态。');
  // 两个布局快捷函数：col 纵向排列，text 生成文字节点。
  // spacing 控制间距；size 控制字号；primary / secondary 分别表示主要/次要文字色。
  const col = (children, spacing) => ({type:'column',spacing:spacing===undefined?5:spacing,children:children});
  const text = (value,size,color,weight) => ({type:'text',text:value,size:size,color:color||'primary',weight:weight||'regular'});
  // 根据周期长度命名：10080 分钟 = 7 天，300 分钟 = 5 小时。
  // 其他非零周期换算为整小时；周期缺失时只显示「额度」。
  const name = w => w.windowDurationMins===10080?'周额度':w.windowDurationMins===300?'5 小时':w.windowDurationMins?'额度 · '+Math.round(w.windowDurationMins/60)+' 小时':'额度';
  // 未知额度保留为 null，显示「—」；有效数字限制在 0～100，防止进度条越界。
  // 数字显示时取整，进度条仍使用未取整的百分比。
  const remaining = w => w.remainingPercent===null || !Number.isFinite(w.remainingPercent) ? null : Math.max(0,Math.min(100,w.remainingPercent));
  // 颜色按剩余额度变化：未知用次要色，≤15% 红色，≤35% 橙色，其余用主题色。
  // 想调整提醒阈值改这里；桌面组件处于系统着色模式时，实际颜色由原生视图适配。
  const accent = w => remaining(w)===null?'secondary':remaining(w)<=15?'red':remaining(w)<=35?'orange':'accent';
  // 将接口的秒时间戳乘 1000，转换成 JavaScript Date 使用的毫秒。
  // 使用本机时区显示「月/日 时:分」；compact 为 true 时省略「重置」前缀以节省空间。
  function reset(w, compact) {
    if (!w.resetsAt) return '重置时间未知';
    const date = new Date(w.resetsAt*1000);
    const pad = n => String(n).padStart(2,'0');
    const clock = pad(date.getHours())+':'+pad(date.getMinutes());
    return (compact?'':'重置 ')+(date.getMonth()+1)+'/'+date.getDate()+' '+clock;
  }
  // 卡片内的标题和图标；这里的 terminal 是布局自身的图标，与组件配置中的图标独立。
  const header = {type:'row',spacing:6,children:[{type:'symbol',symbol:'terminal',size:13},text('Codex',14,'secondary','semibold')]};
  // 单个额度周期的通用布局：名称和百分比一行，下方是进度条、重置时间。
  // spacer 撑开中间的空白，让百分比靠右；size 控制该百分比的字号。
  function row(w, size, compact) {
    const r=remaining(w);
    const children=[
      {type:'row',children:[text(name(w),10,'secondary'),{type:'spacer'},text(r===null?'—':Math.round(r)+'%',size,accent(w),'semibold')]},
      // 未知额度只为绘制进度条临时按 0 填充；上方文字仍是「—」，并不代表额度已耗尽。
      {type:'progress',value:r===null?0:r,max:100,color:accent(w),label:name(w)},
      text(reset(w,compact),9,'secondary')
    ];
    return col(children,3);
  }
  // 小号桌面布局：只有一个周期时放大数值；有两个周期时纵向紧凑排列。
  // 常用调整位置：单周期数值字号 36、双周期数值字号 18，以及各 col 的间距参数。
  let card;
  if (windows.length===1) {
    const w=windows[0],r=remaining(w);
    card=col([header,text(name(w),10,'secondary'),text(r===null?'—':Math.round(r)+'%',36,accent(w),'bold'),
      {type:'progress',value:r===null?0:r,max:100,color:accent(w)},text(reset(w,false),9,'secondary')],5);
  } else { card=col([header].concat(windows.map(w=>row(w,18,true))),7); }
  // 菜单栏展开页和大号桌面组件：使用字号 27、间距 14 的完整周期列表。
  const detailed=col([header].concat(windows.map(w=>row(w,27,false))),14);
  // 中号桌面组件：横向并排显示各周期，充分利用更宽的卡片。
  // 这里的 || 0 同样只用于进度条回退；未知百分比的文字仍显示「—」。
  const medium=col([header,{type:'row',spacing:20,children:windows.map(w=>col([
    text(name(w),11,'secondary'),text(remaining(w)===null?'—':Math.round(remaining(w))+'%',32,accent(w),'bold'),
    {type:'progress',value:remaining(w)||0,max:100,color:accent(w)},text(reset(w,false),10,'secondary')
  ],6))}],10);
  // 菜单栏空间有限：取所有已知周期中最少的剩余额度，突出最接近耗尽的周期。
  // 不是两个周期求平均；如果全部未知，则显示「C —」。
  const valid=windows.map(remaining).filter(v=>v!==null);
  // menuBar：菜单栏文字；panel：展开页；widget / medium / large：三种桌面尺寸。
  // 桌面布局交给 macOS 渲染和调度刷新，脚本不自行绘制玻璃背景或控制隐藏时机。
  return {menuBar:'C '+(valid.length?Math.round(Math.min.apply(null,valid))+'%':'—'),panel:detailed,widget:card,medium:medium,large:detailed};
}
