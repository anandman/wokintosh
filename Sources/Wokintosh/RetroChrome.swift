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
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Rectangle().fill(Color.white).overlay(Rectangle().stroke(.black, lineWidth: 1.4)).overlay(Rectangle().stroke(.gray, lineWidth: 2).padding(3)).frame(width: 16, height: 16)
                Stripes()
                Text(title).font(barFont()).fixedSize()
                Stripes()
                if !suffix.isEmpty { Text(suffix).font(barFont(18)).fixedSize() }
                Rectangle().stroke(.black, lineWidth: 1.4).background(.white).frame(width: 14,height:14)
            }.padding(.horizontal, 8).frame(height: 28).background(Color(white:0.88))
            Rectangle().fill(.black).frame(height: 1.5)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.retroPaper)
        .overlay(Rectangle().stroke(selected ? Color.retroPurple : .black, lineWidth: selected ? 3 : 1.7))
        .compositingGroup()
        .shadow(color: .black.opacity(0.85), radius: 0, x: 3, y: 4)
        .foregroundStyle(.black)
    }
}
struct MacMark: View {
    var body: some View {
        if let image = NSImage(named: "mac") ?? Bundle.module.url(forResource: "mac", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
        } else { Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundStyle(.black) }
    }
}
struct ProviderMark: View {
    let provider: String
    var body: some View {
        if provider == "codex" {
            if let url=Bundle.module.url(forResource:"codex",withExtension:"png"),let image=NSImage(contentsOf:url) {
                Image(nsImage:image).resizable().scaledToFit()
            } else { Text("C").font(.system(size:24,weight:.bold)).foregroundStyle(Color.retroPurple) }
        } else {
            Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(Color(red:0.78,green:0.34,blue:0.23)).padding(5)
        }
    }
}
struct StatusDot: View {
    let state: WokintoshCore.AgentState
    var connected = true
    var tint: Color { if !connected { return .gray }; switch state { case .needsAttention: return Color(red:0.78,green:0.42,blue:0); case .working: return Color(red:0,green:0.5,blue:0.08); case .finished: return .retroPurple; case .idle, .unknown: return .gray } }
    var body: some View { Circle().fill(tint).overlay(Circle().stroke(.black.opacity(0.25),lineWidth:1)) }
}
import WokintoshCore
