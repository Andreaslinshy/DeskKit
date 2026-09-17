import SwiftUI
import AppKit

private struct ComponentSymbol: Identifiable {
    let id: String
    let name: String
}
private struct SymbolCategory: Identifiable {
    let id: String
    let symbols: [ComponentSymbol]
    init(_ name: String, _ items: [(String, String)]) {
        id = name
        symbols = items.map { ComponentSymbol(id: $0.0, name: $0.1) }
    }
}

struct SymbolPicker: View {
    let selected: String
    let select: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 8)
    private static let categories = [
        SymbolCategory("系统与设备", [("cpu","处理器"),("memorychip","内存"),("internaldrive","磁盘"),("externaldrive","外置硬盘"),("desktopcomputer","电脑"),("laptopcomputer","笔记本"),("server.rack","服务器"),("battery.100","电池"),("keyboard","键盘"),("printer","打印机")]),
        SymbolCategory("网络与开发", [("network","网络"),("wifi","无线网络"),("antenna.radiowaves.left.and.right","信号"),("globe","互联网"),("terminal","终端"),("chevron.left.forwardslash.chevron.right","代码"),("curlybraces","程序"),("hammer","构建"),("ladybug","调试"),("externaldrive.connected.to.line.below","数据连接")]),
        SymbolCategory("数据与财务", [("chart.line.uptrend.xyaxis","趋势"),("chart.bar","统计"),("chart.pie","占比"),("chart.xyaxis.line","数据图表"),("dollarsign.circle","金额"),("yensign.circle","人民币"),("creditcard","银行卡"),("banknote","现金"),("percent","额度百分比"),("gauge.with.dots.needle.67percent","仪表盘")]),
        SymbolCategory("时间与效率", [("clock","时钟"),("timer","计时器"),("alarm","闹钟"),("calendar","日历"),("checklist","任务清单"),("checkmark.circle","完成"),("flag","目标"),("bookmark","收藏"),("note.text","笔记"),("doc.text","文档")]),
        SymbolCategory("天气与自然", [("sun.max","晴天"),("moon","月亮"),("cloud","多云"),("cloud.rain","下雨"),("cloud.snow","降雪"),("cloud.bolt","雷电"),("wind","风"),("thermometer.medium","温度"),("drop","湿度"),("leaf","自然")]),
        SymbolCategory("生活与健康", [("heart","健康"),("cross.case","医疗"),("figure.walk","步行"),("figure.run","运动"),("flame","热量"),("bed.double","睡眠"),("cup.and.saucer","咖啡"),("fork.knife","饮食"),("house","家"),("lightbulb","灵感")]),
        SymbolCategory("媒体与沟通", [("music.note","音乐"),("headphones","耳机"),("play.circle","播放"),("photo","照片"),("camera","相机"),("film","视频"),("mic","录音"),("bubble.left.and.bubble.right","聊天"),("envelope","邮件"),("bell","通知")]),
        SymbolCategory("出行与工具", [("location","位置"),("map","地图"),("car","汽车"),("airplane","航班"),("tram","公共交通"),("shippingbox","快递"),("lock.shield","安全"),("sparkles","智能"),("gamecontroller","游戏"),("wrench.and.screwdriver","工具")])
    ]
    private var filtered: [SymbolCategory] {
        Self.categories.compactMap { category in
            let symbols = category.symbols.filter { symbol in
                NSImage(systemSymbolName: symbol.id, accessibilityDescription: nil) != nil &&
                (search.isEmpty || category.id.localizedCaseInsensitiveContains(search) || symbol.name.localizedCaseInsensitiveContains(search) || symbol.id.localizedCaseInsensitiveContains(search))
            }
            return symbols.isEmpty ? nil : SymbolCategory(category.id, symbols.map { ($0.id, $0.name) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择图标").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭")
            }
            TextField("搜索图标或功能", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(filtered) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.id).font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(category.symbols) { symbol in
                                    Button {
                                        if select(symbol.id) { dismiss() }
                                    } label: {
                                        Image(systemName: symbol.id).font(.system(size: 19))
                                            .frame(width: 38, height: 38)
                                            .foregroundStyle(selected == symbol.id ? Color.teal : Color.primary)
                                            .background(selected == symbol.id ? Color.teal.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == symbol.id ? Color.teal : .clear))
                                    }.buttonStyle(.plain).help(symbol.name).accessibilityLabel(symbol.name)
                                }
                            }
                        }
                    }
                    if filtered.isEmpty { Text("没有匹配的图标").foregroundStyle(.secondary).padding(.vertical, 30) }
                }
            }
        }.padding(18).frame(width: 408, height: 470)
    }
}
