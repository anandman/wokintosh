import SwiftUI
import WokintoshCore

private struct MetricReading {
    let label:String
    let value:String
    let compactValue:String
    let qualifier:String
    let fraction:Double?
}

struct SystemWidget: View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        GeometryReader { g in
            let (_,value,connected)=store.system(for:widget)
            let t=store.document.textScale
            let items=readings(value)
            let valueFont=NSFont(name:"Arial-BoldMT",size:26*t) ?? NSFont.boldSystemFont(ofSize:26*t)
            let valueWidth=(items.map{($0.compactValue as NSString).size(withAttributes:[.font:valueFont]).width}.max() ?? 0)/t+2
            let layout=SystemMetricLayout(width:g.size.width,height:g.size.height,textScale:t,count:items.count,minimumColumnWidth:valueWidth)
            VStack(alignment:.leading,spacing:layout.spacing) {
                if items.isEmpty {Text("Choose readings").font(retroFont(20*t,bold:false)).lineLimit(1).help("Choose readings in Dashboard settings.")}
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:layout.horizontalSpacing,alignment:.leading),count:layout.columns),alignment:.leading,spacing:layout.spacing) {
                    ForEach(Array(items.prefix(layout.capacity).enumerated()),id:\.offset) {_,item in
                        metric(item,t:t,compact:layout.compact,columnar:layout.columnar).frame(height:layout.rowHeight)
                    }
                }
                if items.count>layout.capacity {
                    Text("+\(items.count-layout.capacity) more · enlarge to show")
                        .font(retroFont(17*t,bold:false)).lineLimit(1).frame(height:layout.overflowHeight,alignment:.leading)
                }
            }.padding(layout.padding).opacity(connected ? 1 : 0.45).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            if !connected {Text("Source unavailable").font(retroFont(18)).foregroundStyle(.orange).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing).padding(5)}
        }
    }
    private func readings(_ value:SystemReading)->[MetricReading] {
        var result:[MetricReading]=[]
        if widget.systemOptions.showCPU {
            let text=value.cpuPercent.map{String(format:"%.0f%%",$0)} ?? "—"
            result.append(MetricReading(label:"CPU",value:text,compactValue:text,qualifier:"",fraction:SystemMetricFraction.cpu(value.cpuPercent)))
        }
        if widget.systemOptions.showMemory {
            result.append(MetricReading(label:"RAM",value:bytes(value.memoryUsedBytes),compactValue:compactBytes(value.memoryUsedBytes,fractional:true),qualifier:"used",fraction:SystemMetricFraction.used(value.memoryUsedBytes,total:value.memoryTotalBytes)))
        }
        if widget.systemOptions.showStorage {
            result += store.selectedDrives(for:widget).map { drive in
                MetricReading(label:drive.name.isEmpty ? drive.mountPoint : drive.name,value:bytes(drive.freeBytes)+" free",compactValue:compactBytes(drive.freeBytes),qualifier:"free",fraction:SystemMetricFraction.driveUsed(free:drive.freeBytes,total:drive.totalBytes))
            }
        }
        return result
    }
    private func metric(_ item:MetricReading,t:Double,compact:Bool,columnar:Bool)->some View {
        VStack(alignment:.leading,spacing:(columnar ? 5 : (compact ? 2 : 4))*t) {
            if columnar {
                HStack(spacing:3) {
                    Text(item.label).lineLimit(1)
                    if !item.qualifier.isEmpty {Text(item.qualifier).fixedSize()}
                }.font(retroFont(18*t,bold:false))
                Text(item.compactValue).font(retroFont(26*t)).lineLimit(1)
            } else if compact {
                HStack(spacing:5) {
                    Text(item.label).font(retroFont(16*t)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    Text(item.compactValue+(item.qualifier == "free" ? " free":"")).font(retroFont(22*t)).lineLimit(1).fixedSize(horizontal:true,vertical:false).layoutPriority(1)
                }.frame(height:26*t)
            } else {
                Text(item.label).font(retroFont(18*t)).lineLimit(1)
                Text(item.value).font(retroFont(28*t)).lineLimit(1)
            }
            Group {
                if let fraction=item.fraction { GeometryReader { geometry in
                    ZStack(alignment:.leading) {
                        Color.black.opacity(0.07)
                        Rectangle().fill(.black.opacity(0.68)).frame(width:geometry.size.width*fraction)
                    }.overlay(Rectangle().stroke(.black.opacity(0.35),lineWidth:0.7))
                } }
                else { Rectangle().fill(.clear).overlay(Rectangle().stroke(.black.opacity(0.4),lineWidth:1)).overlay(Text("—").font(.system(size:9))) }
            }.frame(height:(columnar || compact ? 5 : 10)*t)
        }
        .frame(maxWidth:.infinity,alignment:.leading)
        .accessibilityElement(children:.combine)
        .accessibilityLabel("\(item.label), \(item.value)")
        .help("\(item.label): \(item.value)\n"+(item.fraction.map{String(format:"%.0f%% used",$0*100)} ?? "Usage unavailable"))
    }
    private func bytes(_ value:UInt64?)->String {value.map{ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.memory)} ?? "—"}
    private func compactBytes(_ value:UInt64?,fractional:Bool=false)->String {
        guard let value else {return "—"}
        let units=["B","KB","MB","GB","TB","PB","EB"]
        var amount=Double(value),unit=0
        while amount>=1024 && unit<units.count-1 {amount/=1024;unit+=1}
        let format=NumberFormatter();format.numberStyle = .decimal
        format.maximumFractionDigits=fractional || amount<10 ? 1 : 0
        return (format.string(from:NSNumber(value:amount)) ?? "—")+" "+units[unit]
    }
}
