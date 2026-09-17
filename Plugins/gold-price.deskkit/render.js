// 国内金价：解析行情文本，显示价格、涨跌幅和报价时间。
// widget.json 使用 HTTP 数据源，source.format = "text"，响应正文由 DeskKit 放进 data.text。
// 更换数据地址请改 source.url；更改采集间隔请改 refreshSeconds。
// 请求由应用完成，render 只负责解析并同步返回布局对象。
// context.now 是本次渲染的毫秒时间戳，context.locale 是语言；本组件目前都未使用。
function render(data, context) {
  // 从响应正文中提取 hq_str_gds_AUTD="..." 的引号内内容。
  // 这里只读取指定行情字符串，不执行接口返回的 JavaScript。
  // 如果接口改了变量名或数据结构，需要相应调整这个正则和下方字段索引。
  const match = String(data.text || '').match(/hq_str_gds_AUTD="([^"]+)"/);
  // 没有匹配到预期格式时直接报错，避免把解析失败显示成价格 0。
  if (!match) throw new Error('行情格式已变化，暂时无法解析。');
  // 按逗号拆分，数组下标从 0 开始。本脚本目前按以下字段位置解析：
  // d[0] 当前价；d[4]/d[5] 最高/最低；d[6] 报价时间；
  // d[7] 昨收（涨跌比较基准）；d[8] 开盘；d[12] 报价日期。
  // 这些位置与当前解析格式绑定，更换数据源时需要重新核对，不能直接套用。
  const d=match[1].split(','), price=Number(d[0]), previous=Number(d[7]);
  // 当前价和昨收都必须是有限正数；昨收还会用于除法，不能为 0。
  // 解析失败交给应用显示错误状态，并保留已有的成功数据。
  if (!Number.isFinite(price)||!Number.isFinite(previous)||previous<=0||price<=0) throw new Error('行情价格无效。');
  // 涨跌额 = 当前价 - 昨收；涨跌幅 = 涨跌额 / 昨收 × 100。
  // 采用红涨绿跌，持平也按红色处理；上涨和持平加「+」，负数自带「-」。
  // 想换配色或改变持平样式，调整这里的 color / sign 判断。
  const change=price-previous,percent=change/previous*100,color=change>=0?'red':'green',sign=change>=0?'+':'';
  // 文字节点快捷函数：t 是内容，s 是字号，c 是颜色，省略颜色时使用主要文字色。
  const text=(t,s,c)=>({type:'text',text:t,size:s,color:c||'primary'});
  // 小号桌面卡片：标题、当前价、涨跌额/幅、报价日期与时间，按 children 顺序排列。
  // spacing 控制行间距，当前价字号为 30；toFixed(2) 只控制显示为两位小数。
  // 日期和时间来自行情本身，可能早于应用的最近采集时间；这里没有用本机时间替代。
  const card={type:'column',spacing:7,children:[text('国内黄金 · 元/克',11,'secondary'),
    {type:'text',text:price.toFixed(2),size:30,weight:'semibold',color:color},
    text(sign+change.toFixed(2)+'  '+sign+percent.toFixed(2)+'%',12,color),
    text((d[12]||'')+' '+(d[6]||''),9,'secondary')]};
  // 菜单栏展开页：先复用小卡片，再附加最高/最低、开盘/昨收两组指标。
  // 这份较详细的布局也用于中号桌面组件。
  const panel={type:'column',spacing:12,children:[card,{type:'divider'},
    {type:'metric',label:'最高 / 最低',text:d[4]+' / '+d[5]},
    {type:'metric',label:'开盘 / 昨收',text:d[8]+' / '+previous.toFixed(2)}]};
  // menuBar 是菜单栏的简短报价；panel 是展开页；widget / medium 是桌面布局。
  // 是否显示在菜单栏或桌面由组件的两个复选框控制。
  return {menuBar:'金 '+price.toFixed(2),panel:panel,widget:card,medium:panel};
}
