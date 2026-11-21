import SwiftUI
import UIKit

// Same palette and provider artwork as the desktop's RetroChrome.swift.
enum PhonePalette {
    static let desktop=Color(red:0,green:0.55,blue:0.55)
    static let paper=Color(red:0.965,green:0.962,blue:0.918)
    static let chrome=Color(white:0.88)
    static let purple=Color(red:0.37,green:0.32,blue:0.91)
    static let attention=Color(red:0.60,green:0.29,blue:0)
    static let working=Color(red:0,green:0.42,blue:0.06)
    static let secondary=Color(white:0.32)
    static let widgetPaper=Color(uiColor:UIColor {traits in traits.userInterfaceStyle == .dark ? UIColor(white:0.12,alpha:1) : UIColor(red:0.965,green:0.962,blue:0.918,alpha:1)})
    static let widgetChrome=Color(uiColor:UIColor {traits in traits.userInterfaceStyle == .dark ? UIColor(white:0.23,alpha:1) : UIColor(white:0.88,alpha:1)})
    static let widgetPurple=Color(uiColor:UIColor {traits in traits.userInterfaceStyle == .dark ? UIColor(red:0.72,green:0.66,blue:1,alpha:1) : UIColor(red:0.37,green:0.32,blue:0.91,alpha:1)})
    static let widgetAttention=Color(uiColor:UIColor {traits in traits.userInterfaceStyle == .dark ? UIColor(red:1,green:0.66,blue:0.30,alpha:1) : UIColor(red:0.60,green:0.29,blue:0,alpha:1)})
    static let widgetWorking=Color(uiColor:UIColor {traits in traits.userInterfaceStyle == .dark ? UIColor(red:0.35,green:0.9,blue:0.42,alpha:1) : UIColor(red:0,green:0.42,blue:0.06,alpha:1)})
    static func font(_ size:CGFloat=17,bold:Bool=false,relativeTo style:Font.TextStyle = .body)->Font {
        .custom(bold ? "Arial-BoldMT" : "ArialMT",size:size,relativeTo:style)
    }
}
enum PhoneProviderArtwork {
    // WidgetKit budgets the source raster, even when SwiftUI displays it at 22 pt.
    // Keep the desktop artwork and cache a thumbnail sharp enough for a 3× display.
    private static let codex=UIImage(named:"PhoneCodex").flatMap(thumbnail)
    private static let claude=UIImage(named:"PhoneClaude").flatMap(thumbnail)
    static func thumbnail(_ image:UIImage)->UIImage? {
        image.preparingThumbnail(of:CGSize(width:66,height:66))
    }
    static func image(for provider:String)->UIImage? {provider=="codex" ? codex : claude}
}
struct PhoneProviderMark:View {
    let provider:String
    var body:some View {
        Group {
            if let image=PhoneProviderArtwork.image(for:provider) {
                Image(uiImage:image).resizable().scaledToFit()
            } else {
                Image(systemName:provider=="codex" ? "terminal" : "sparkle").resizable().scaledToFit()
            }
        }.accessibilityLabel(provider=="codex" ? "Codex" : "Claude Code")
    }
}
struct PhoneStripes:View {
    var body:some View {
        Canvas {context,size in
            for y in stride(from:2.0,through:size.height,by:3.4) {
                var path=Path();path.move(to:CGPoint(x:0,y:y));path.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(path,with:.color(.primary.opacity(0.55)),lineWidth:1)
            }
        }.frame(height:16).accessibilityHidden(true)
    }
}
struct PhoneRainbowMark:View {
    private let colors:[Color]=[Color(red:0.20,green:0.67,blue:0.28),Color(red:1,green:0.82,blue:0.15),Color(red:1,green:0.51,blue:0.14),Color(red:0.89,green:0.22,blue:0.22),Color(red:0.67,green:0.12,blue:0.69),Color(red:0,green:0.62,blue:0.80)]
    var body:some View {VStack(spacing:0){ForEach(colors.indices,id:\.self){colors[$0]}}.overlay(Rectangle().stroke(.black,lineWidth:1)).accessibilityHidden(true)}
}
struct PhoneRetroWindow<Content:View>:View {
    let title:String
    @ViewBuilder let content:()->Content
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Rectangle().stroke(.black,lineWidth:1).frame(width:12,height:12).overlay(Rectangle().stroke(.gray,lineWidth:1).padding(3)).accessibilityHidden(true)
                PhoneStripes()
                Text(title).font(PhonePalette.font(18,bold:true,relativeTo:.headline)).lineLimit(1).layoutPriority(1)
                PhoneStripes()
            }.padding(.horizontal,8).padding(.vertical,6).background(PhonePalette.chrome)
            Rectangle().fill(.black).frame(height:1)
            content()
        }.foregroundStyle(.black).background(PhonePalette.paper)
            .overlay(Rectangle().stroke(.black,lineWidth:1.5).allowsHitTesting(false))
            .compositingGroup().shadow(color:.black.opacity(0.8),radius:0,x:3,y:3)
    }
}
struct PhoneRetroButtonStyle:ButtonStyle {
    var prominent=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(PhonePalette.font(16,bold:true)).padding(.horizontal,12).frame(minHeight:44)
            .foregroundStyle(.black).background(configuration.isPressed ? PhonePalette.chrome : (prominent ? Color.white : PhonePalette.paper))
            .overlay(Rectangle().stroke(.black,lineWidth:prominent ? 2 : 1))
            .compositingGroup().shadow(color:.black.opacity(configuration.isPressed ? 0 : 0.7),radius:0,x:2,y:2)
            .contentShape(Rectangle())
    }
}
struct PhoneSessionButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.background(configuration.isPressed ? PhonePalette.purple.opacity(0.12) : .clear).contentShape(Rectangle())
    }
}
