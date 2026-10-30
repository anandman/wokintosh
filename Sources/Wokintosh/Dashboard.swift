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
                        if editing {
                            Canvas { context, size in
                                for x in stride(from:0.0,through:size.width,by:32) {
                                    var p=Path();p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height));context.stroke(p,with:.color(.white.opacity(0.10)),lineWidth:0.6)
                                }
                                for y in stride(from:0.0,through:size.height,by:32) {
                                    var p=Path();p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y));context.stroke(p,with:.color(.white.opacity(0.10)),lineWidth:0.6)
                                }
                            }.allowsHitTesting(false)
                        }
                        ForEach(store.document.widgets) { widget in
                            PlacedWidget(store:store,widget:widget,canvasSize:canvas.size,editing:editing)
                        }
                    }
                }
            }
            .frame(width:1280,height:720)
            .background(Color.retroDesktop)
            .scaleEffect(scale,anchor:.topLeading)
            .frame(width:1280*scale,height:720*scale,alignment:.topLeading)
            .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }.background(Color.black.opacity(0.88))
    }
    var menuBar: some View {
        HStack(spacing: 12) {
            MacMark().frame(width:25,height:27)
            Button("Wokintosh") { store.showEditor?() }.buttonStyle(.plain).font(barFont(23)).help("Open Layout Editor")
            Spacer()
            if store.document.previewMode { Text("PREVIEW").font(barFont(16)).foregroundStyle(.orange) }
            if store.offlineCount > 0 && !store.document.previewMode { Text("\(store.offlineCount) disconnected").font(barFont(16)).foregroundStyle(.orange) }
            Spacer()
            TimelineView(.periodic(from:.now,by:1)) { context in Text(context.date.formatted(date:.omitted,time:.shortened)).font(barFont(21)).monospacedDigit() }
            Button { store.showEditor?() } label: { MacMark().frame(width:26,height:27) }.buttonStyle(.plain).help("Dashboard settings")
        }.padding(.horizontal,16).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(white:0.91)).foregroundStyle(.black)
            .overlay(alignment:.bottom) { Rectangle().fill(.black).frame(height:1.5) }
    }
}

struct PlacedWidget: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    let canvasSize: CGSize
    let editing: Bool
    @State private var moveStart: WidgetFrame?
    @State private var resizeStart: WidgetFrame?
    var body: some View {
        let frame=widget.frame
        let width=frame.width*canvasSize.width
        let height=frame.height*canvasSize.height
        RetroWindow(title:widget.kind.title,suffix:suffix,selected:editing && store.selectedID==widget.id) {
            WidgetContent(store:store,widget:widget)
        }
        .overlay(alignment:.top) {
            if editing {
                Color.clear.frame(height:28).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:1).onChanged { value in
                        store.selectedID=widget.id
                        if moveStart == nil { moveStart=widget.frame }
                        guard let start=moveStart else{return}
                        store.change(widget.id) { $0.frame=WidgetFrame(x:start.x+value.translation.width/canvasSize.width,y:start.y+value.translation.height/canvasSize.height,width:start.width,height:start.height) }
                    }.onEnded { _ in moveStart=nil;store.saveNow() })
            }
        }
        .overlay(alignment:.bottomTrailing) {
            if editing {
                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:12,weight:.bold)).foregroundStyle(.white).padding(5).background(Color.retroPurple)
                    .contentShape(Rectangle()).accessibilityLabel("Resize \(widget.kind.title) widget")
                    .gesture(DragGesture(minimumDistance:1).onChanged { value in
                        store.selectedID=widget.id
                        if resizeStart == nil { resizeStart=widget.frame }
                        guard let start=resizeStart else{return}
                        store.change(widget.id) { $0.frame=WidgetFrame(x:start.x,y:start.y,width:start.width+value.translation.width/canvasSize.width,height:start.height+value.translation.height/canvasSize.height) }
                    }.onEnded { _ in resizeStart=nil;store.saveNow() })
            }
        }
        .frame(width:width,height:height)
        .onTapGesture { if editing { store.selectedID=widget.id } }
        .position(x:(frame.x+frame.width/2)*canvasSize.width,y:(frame.y+frame.height/2)*canvasSize.height)
        .contextMenu {
            if editing {
                Button("Select") { store.selectedID=widget.id }
                Button("Duplicate") { store.selectedID=widget.id;store.duplicateSelected() }
                Button("Remove",role:.destructive) { store.selectedID=widget.id;store.removeSelected() }
            } else { Button("Edit Layout…") { store.showEditor?() } }
        }
    }
    var suffix: String {
        if widget.kind == .agents { return "\(store.rows(for:widget).count) sessions" }
        if widget.kind == .system { return store.system(for:widget).0 }
        return ""
    }
}
