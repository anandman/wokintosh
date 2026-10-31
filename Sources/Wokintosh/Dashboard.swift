import AppKit
import SwiftUI
import WokintoshCore

struct DashboardCanvas: View {
    @ObservedObject var store: DashboardStore
    var editing: Bool
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 1280, geometry.size.height / 720)
            VStack(spacing: 0) {
                menuBar.frame(height: 38)
                GeometryReader { canvas in
                    ZStack(alignment: .topLeading) {
                        Color.retroDesktop
                        if editing && store.document.snapToGrid {
                            Canvas { context, size in
                                for x in stride(from:0.0,through:size.width,by:DashboardGrid.step) {
                                    var p=Path();p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height));context.stroke(p,with:.color(.white.opacity(0.10)),lineWidth:0.6)
                                }
                                for y in stride(from:0.0,through:size.height,by:DashboardGrid.step) {
                                    var p=Path();p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y));context.stroke(p,with:.color(.white.opacity(0.10)),lineWidth:0.6)
                                }
                            }.allowsHitTesting(false)
                        }
                        ForEach(store.document.widgets) { widget in
                            PlacedWidget(store:store,widget:widget,canvasSize:canvas.size,editing:editing)
                        }
                    }.coordinateSpace(name:"dashboard-canvas")
                }
            }
            .frame(width:1280,height:720)
            .background(Color.retroDesktop)
            .scaleEffect(scale,anchor:.topLeading)
            .frame(width:1280*scale,height:720*scale,alignment:.topLeading)
            .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }.background(Color.black.opacity(0.88))
            .environment(\.colorScheme,.light)
    }
    var menuBar: some View {
        HStack(spacing: 12) {
            ColorStripeMark().frame(width:25,height:25)
            Button("Wokintosh") { store.showEditor?() }.buttonStyle(.plain).font(barFont(23)).help("Edit dashboard")
            Spacer()
            if store.document.previewMode { Text("PREVIEW").font(barFont(16)).foregroundStyle(.orange) }
            if store.offlineCount > 0 && !store.document.previewMode { Text("\(store.offlineCount) disconnected").font(barFont(16)).foregroundStyle(.orange) }
            Spacer()
            TimelineView(.periodic(from:.now,by:1)) { context in Text(context.date.formatted(date:.omitted,time:.shortened)).font(barFont(21)).monospacedDigit() }
            Button { store.openSettings(.widgets) } label: { MacMark().frame(width:26,height:27) }.buttonStyle(.plain).help("Dashboard & Settings").accessibilityLabel("Open Dashboard & Settings")
        }.padding(.horizontal,16).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(white:0.91)).foregroundStyle(.black)
            .overlay(alignment:.bottom) { Rectangle().fill(.black).frame(height:1.5) }
    }
}

struct WidgetActions: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    var body: some View {
        Button("Configure…") { store.configure(widget.id) }
        Button("Duplicate") { store.duplicate(widget.id) }
        Button("Remove",role:.destructive) { store.remove(widget.id) }
    }
}

struct PlacedWidget: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    let canvasSize: CGSize
    let editing: Bool
    @State private var start: WidgetFrame?
    @State private var draft: WidgetFrame?
    var body: some View {
        let frame=draft ?? widget.frame
        RetroWindow(title:widget.kind.title,suffix:suffix,selected:editing && store.selectedID==widget.id,
                    onClose:editing ? { store.remove(widget.id) } : nil,
                    onSelect:editing ? { store.configure(widget.id) } : nil,
                    onMove:editing ? { translation,ended in interact(translation,ended:ended,resizing:false) } : nil) {
            WidgetContent(store:store,widget:widget)
        }
        .overlay(alignment:.bottomTrailing) {
            if editing {
                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:12,weight:.bold)).foregroundStyle(.white).padding(5).background(Color.retroPurple)
                    .contentShape(Rectangle()).accessibilityLabel("Resize \(widget.kind.title) widget")
                    .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("dashboard-canvas"))
                        .onChanged { interact($0.translation,ended:false,resizing:true) }
                        .onEnded { interact($0.translation,ended:true,resizing:true) })
            }
        }
        .frame(width:frame.width*canvasSize.width,height:frame.height*canvasSize.height)
        .onTapGesture { if editing && store.selectedID != widget.id { store.selectedID=widget.id } }
        .position(x:(frame.x+frame.width/2)*canvasSize.width,y:(frame.y+frame.height/2)*canvasSize.height)
        .transaction { $0.animation=nil }
        .contextMenu {
            if editing { WidgetActions(store:store,widget:widget) }
            else {
                Button("Configure…") { store.configure(widget.id) }
                if widget.kind == .agents { Button("Mark all Done as reviewed") { store.reviewAllCompletions(for:widget) }.disabled(!store.rows(for:widget).contains(where: \.completionPending)) }
                Button("Edit Dashboard…") { store.showEditor?() }
            }
        }
    }
    private func interact(_ translation:CGSize,ended:Bool,resizing:Bool) {
        if start == nil { start=widget.frame; if store.selectedID != widget.id { store.selectedID=widget.id } }
        guard let start else { return }
        let dx=translation.width*1280/canvasSize.width,dy=translation.height*682/canvasSize.height
        let result=resizing ? WidgetInteraction.resizing(start,dx:dx,dy:dy,kind:widget.kind,snap:store.document.snapToGrid) : WidgetInteraction.moving(start,dx:dx,dy:dy,snap:store.document.snapToGrid)
        if ended { store.change(widget.id) { $0.frame=result };self.start=nil;draft=nil }
        else { draft=result }
    }
    var suffix:String {
        if widget.kind == .agents { let count=store.rows(for:widget).count;return "\(count) \(count == 1 ? "session" : "sessions")" }
        return widget.kind == .system ? store.system(for:widget).0 : ""
    }
}
