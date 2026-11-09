import SwiftUI
import WokintoshCore

private struct MetricReading {
    let symbol:String
    let tint:Color
    let detail:String
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
            let labelFont=NSFont(name:"ArialMT",size:18*t) ?? NSFont.systemFont(ofSize:18*t)
            let inlineLabelFont=NSFont(name:"Arial-BoldMT",size:16*t) ?? NSFont.boldSystemFont(ofSize:16*t)
            let compactLabelFont=NSFont(name:"ArialMT",size:16*t) ?? NSFont.systemFont(ofSize:16*t)
            let compactValueFont=NSFont(name:"Arial-BoldMT",size:20*t) ?? NSFont.boldSystemFont(ofSize:20*t)
            let inlineValueFont=NSFont(name:"Arial-BoldMT",size:22*t) ?? NSFont.boldSystemFont(ofSize:22*t)
            let valueWidth=items.map{width($0.compactValue,font:valueFont)}.max() ?? 0
            let labelWidth=items.map{width(heading($0),font:labelFont)+23*t}.max() ?? 0
            let wrappedWidth=items.map{wrappedHeadingWidth(heading($0),font:labelFont)+23*t}.max() ?? 0
            let compactWidth=items.map{max(width(heading($0),font:compactLabelFont)+20*t,width($0.compactValue,font:compactValueFont))}.max() ?? 0
            let inlineWidth=items.map{width($0.label,font:inlineLabelFont)+width(inlineValue($0),font:inlineValueFont)+25*t}.max() ?? 0
            let layout=SystemMetricLayout(width:g.size.width,height:g.size.height,textScale:t,count:items.count,
                                          minimumColumnWidth:max(valueWidth,labelWidth)/t+2,
                                          minimumWrappedColumnWidth:max(valueWidth,wrappedWidth)/t+2,
                                          minimumInlineWidth:inlineWidth/t+2,minimumCompactColumnWidth:compactWidth/t+2,sourceAvailable:connected)
            VStack(spacing:0) {
                VStack(alignment:.leading,spacing:layout.spacing) {
                    if items.isEmpty {Text("Choose readings").font(retroFont(20*t,bold:false)).lineLimit(1).help("Choose readings in Dashboard settings.")}
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:layout.horizontalSpacing,alignment:.leading),count:layout.columns),alignment:.leading,spacing:layout.spacing) {
                        ForEach(Array(items.prefix(layout.capacity).enumerated()),id:\.offset) {_,item in
                            metric(item,t:t,layout:layout).frame(height:layout.rowHeight)
                        }
                    }
                    if items.count>layout.capacity {
                        Text("+\(items.count-layout.capacity) more · enlarge to show")
                            .font(retroFont(17*t,bold:false)).lineLimit(1).frame(height:layout.overflowHeight,alignment:.leading)
                    }
                }.padding(layout.padding).opacity(connected ? 1 : 0.45).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .frame(height:max(0,g.size.height-layout.statusHeight))
                if !connected {
                    Text("Source unavailable").font(retroFont(18*t)).foregroundStyle(.orange).lineLimit(1)
                        .padding(.horizontal,5).frame(maxWidth:.infinity,alignment:.trailing).frame(height:layout.statusHeight)
                }
            }
        }
    }
    private func readings(_ value:SystemReading)->[MetricReading] {
        var result:[MetricReading]=[]
        if widget.systemOptions.showCPU {
            let text=value.cpuPercent.map{String(format:"%.0f%%",$0)} ?? "—"
            result.append(MetricReading(symbol:"cpu",tint:Color(red:0.1,green:0.35,blue:0.65),detail:"CPU utilization",label:"CPU",value:text,compactValue:text,qualifier:"",fraction:SystemMetricFraction.cpu(value.cpuPercent)))
        }
        if widget.systemOptions.showMemory {
            result.append(MetricReading(symbol:"memorychip",tint:.retroPurple,detail:"Memory utilization",label:"RAM",value:bytes(value.memoryUsedBytes)+" used",compactValue:compactBytes(value.memoryUsedBytes,fractional:true),qualifier:"used",fraction:SystemMetricFraction.used(value.memoryUsedBytes,total:value.memoryTotalBytes)))
        }
        if widget.systemOptions.showStorage {
            result += store.selectedDrives(for:widget).map { drive in
                MetricReading(symbol:SystemDrivePresentation.isStartup(drive) ? "internaldrive" : "externaldrive",tint:Color(red:0.12,green:0.44,blue:0.3),detail:SystemDrivePresentation.detail(for:drive),label:SystemDrivePresentation.label(for:drive),value:bytes(drive.freeBytes)+" free",compactValue:compactBytes(drive.freeBytes),qualifier:"free",fraction:SystemMetricFraction.driveUsed(free:drive.freeBytes,total:drive.totalBytes))
            }
        }
        return result
    }
    private func metric(_ item:MetricReading,t:Double,layout:SystemMetricLayout)->some View {
        VStack(alignment:.leading,spacing:0) {
            if layout.stackedCompact {
                HStack(alignment:.top,spacing:5*t) {
                    Image(systemName:item.symbol).foregroundStyle(item.tint).frame(width:15*t)
                    Text(heading(item)).lineLimit(1)
                }.font(retroFont(16*t,bold:false)).frame(height:19*t,alignment:.topLeading)
                Text(item.compactValue).font(retroFont(20*t)).lineLimit(1).padding(.top,t)
                Spacer(minLength:t)
            } else if layout.compact {
                HStack(spacing:5*t) {
                    Image(systemName:item.symbol).font(.system(size:15*t,weight:.semibold)).foregroundStyle(item.tint).frame(width:15*t)
                    Text(item.label).font(retroFont(16*t)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    Text(inlineValue(item)).font(retroFont(22*t)).lineLimit(1).fixedSize(horizontal:true,vertical:false).layoutPriority(1)
                }.frame(height:26*t)
                Spacer(minLength:2*t)
            } else {
                HStack(alignment:.top,spacing:5*t) {
                    Image(systemName:item.symbol).foregroundStyle(item.tint).frame(width:18*t)
                    Text(heading(item)).lineLimit(layout.labelLineLimit).fixedSize(horizontal:false,vertical:true)
                }.font(retroFont(18*t,bold:false))
                    .frame(height:21*t*Double(layout.labelLineLimit),alignment:.topLeading)
                Text(item.compactValue).font(retroFont(26*t)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top,(layout.columnar ? 5 : 2)*t)
                Spacer(minLength:(layout.columnar ? 5 : 2)*t)
            }
            Group {
                if let fraction=item.fraction { GeometryReader { geometry in
                    ZStack(alignment:.leading) {
                        Color.black.opacity(0.07)
                        Rectangle().fill(item.tint).frame(width:geometry.size.width*fraction)
                    }.overlay(Rectangle().stroke(.black.opacity(0.35),lineWidth:0.7))
                } }
                else { Rectangle().fill(.clear).overlay(Rectangle().stroke(.black.opacity(0.4),lineWidth:1)).overlay(Text("—").font(.system(size:9))) }
            }.frame(height:(layout.stackedCompact ? 4 : 5)*t)
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .accessibilityElement(children:.combine)
        .accessibilityLabel("\(item.label), \(item.value)")
        .help("\(item.label): \(item.value)\n\(item.detail)\n"+(item.fraction.map{String(format:"%.0f%% used",$0*100)} ?? "Usage unavailable"))
    }
    private func heading(_ item:MetricReading)->String {item.label+(item.qualifier.isEmpty ? "" : " "+item.qualifier)}
    private func inlineValue(_ item:MetricReading)->String {item.compactValue+(item.qualifier.isEmpty ? "" : " "+item.qualifier)}
    private func width(_ text:String,font:NSFont)->Double {ceil((text as NSString).size(withAttributes:[.font:font]).width)}
    /// Find the width that holds the complete heading on at most two native text lines.
    private func wrappedHeadingWidth(_ text:String,font:NSFont)->Double {
        var lower=1.0,upper=width(text,font:font)
        let lineHeight=ceil(font.ascender-font.descender+font.leading)
        for _ in 0..<12 {
            let mid=(lower+upper)/2
            let bounds=(text as NSString).boundingRect(with:NSSize(width:mid,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
            if bounds.height<=lineHeight*2+0.5 && bounds.width<=mid+0.5 {upper=mid} else {lower=mid}
        }
        return ceil(upper)+2
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
