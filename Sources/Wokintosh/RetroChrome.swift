import SwiftUI

extension Color {
    static let retroDesktop = Color(red: 0.0, green: 0.55, blue: 0.55)
    static let retroPaper = Color(red: 0.965, green: 0.962, blue: 0.918)
    static let retroPurple = Color(red: 0.37, green: 0.32, blue: 0.91)
}
func retroFont(_ size: CGFloat, bold: Bool = true) -> Font { .custom(bold ? "Arial-BoldMT" : "ArialMT", size: size) }
func barFont(_ size: CGFloat = 21) -> Font { .custom("Geneva", size: size).weight(.bold) }

struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            for y in stride(from: 2.0, through: size.height, by: 3.4) {
                var path=Path(); path.move(to: CGPoint(x: 0,y:y)); path.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(path, with: .color(.black.opacity(0.58)), lineWidth: 1)
            }
        }.frame(height: 19)
    }
}
struct RetroWindow<Content: View>: View {
    let title: String
    var suffix: String = ""
    var selected = false
    var onClose: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMove: ((CGSize, Bool) -> Void)?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { onClose?() } label: {
                    Rectangle().fill(.white).overlay(Rectangle().stroke(.black,lineWidth:1.4)).overlay(Rectangle().stroke(.gray,lineWidth:2).padding(3)).frame(width:16,height:16)
                }.buttonStyle(.plain).disabled(onClose == nil).accessibilityLabel("Remove \(title) widget").help("Remove widget")
                HStack(spacing:9) {
                    Stripes()
                    Text(title).font(barFont()).fixedSize()
                    Stripes()
                    if !suffix.isEmpty { Text(suffix).font(barFont(18)).fixedSize() }
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("dashboard-canvas"))
                        .onChanged { onMove?($0.translation,false) }.onEnded { onMove?($0.translation,true) },including:onMove == nil ? .none : .all)
                Button { onSelect?() } label: { Rectangle().stroke(.black,lineWidth:1.4).background(.white).frame(width:14,height:14) }
                    .buttonStyle(.plain).disabled(onSelect == nil).accessibilityLabel("Configure \(title) widget").help("Select widget settings")
            }.padding(.horizontal,8).frame(height:28).background(Color(white:0.88))
            Rectangle().fill(.black).frame(height:1.5)
            content().frame(maxWidth:.infinity,maxHeight:.infinity)
        }.background(Color.retroPaper)
            .overlay(Rectangle().stroke(selected ? Color.retroPurple : .black,lineWidth:selected ? 3 : 1.7).allowsHitTesting(false))
            .compositingGroup().shadow(color:.black.opacity(0.85),radius:0,x:3,y:4).foregroundStyle(.black)
    }
}
private enum RetroAssets {
    static let mac=Bundle.module.url(forResource:"mac",withExtension:"png").flatMap(NSImage.init(contentsOf:))
    static let codex=Bundle.module.url(forResource:"codex",withExtension:"png").flatMap(NSImage.init(contentsOf:))
    static let claude=Bundle.module.url(forResource:"claude",withExtension:"png").flatMap(NSImage.init(contentsOf:))
}
struct MacMark: View {
    var body: some View {
        if let image = RetroAssets.mac {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
        } else { Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundStyle(.black) }
    }
}
struct ProviderMark: View {
    let provider: String
    var body: some View {
        if provider == "codex" {
            if let image=RetroAssets.codex {
                Image(nsImage:image).resizable().scaledToFit()
            } else { Text("C").font(.system(size:24,weight:.bold)).foregroundStyle(Color.retroPurple) }
        } else {
            if let image=RetroAssets.claude { Image(nsImage:image).resizable().scaledToFit() }
            else { Text("C").font(.system(size:24,weight:.bold)).foregroundStyle(Color(red:0.78,green:0.34,blue:0.23)) }
        }
    }
}
struct StatusDot: View {
    let state: WokintoshCore.AgentState
    var connected = true
    var tint: Color { if !connected && state != .blocked { return .gray }; switch state { case .needsAttention, .blocked: return Color(red:0.78,green:0.42,blue:0); case .working: return Color(red:0,green:0.5,blue:0.08); case .finished: return .retroPurple; case .idle, .unknown: return .gray } }
    var body: some View { Circle().fill(tint).overlay(Circle().stroke(.black.opacity(0.25),lineWidth:1)) }
}
import WokintoshCore

/// A cached image also works as a native pull-down menu label on macOS.
enum ColorStripeMark {
    static let image=NSImage(size:NSSize(width:25,height:25),flipped:true) { rect in
        let colors:[NSColor]=[NSColor(red:0.20,green:0.67,blue:0.28,alpha:1),
                              NSColor(red:1,green:0.82,blue:0.15,alpha:1),
                              NSColor(red:1,green:0.51,blue:0.14,alpha:1),
                              NSColor(red:0.89,green:0.22,blue:0.22,alpha:1),
                              NSColor(red:0.67,green:0.12,blue:0.69,alpha:1),
                              NSColor(red:0,green:0.62,blue:0.80,alpha:1)]
        for index in colors.indices {
            colors[index].setFill()
            NSBezierPath(rect:NSRect(x:rect.minX,y:rect.minY+Double(index)*rect.height/6,width:rect.width,height:rect.height/6+0.3)).fill()
        }
        NSColor.black.withAlphaComponent(0.7).setStroke()
        let border=NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5));border.lineWidth=1;border.stroke()
        return true
    }
}
