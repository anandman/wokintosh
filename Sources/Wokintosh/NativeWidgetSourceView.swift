import AppKit
import ImageIO
import SwiftUI
import WokintoshCore

/// Reserve status space so stale/offline indicators cannot cover the readings.
struct NativeWidgetSourceFrame<Content:View>:View {
    let source:RemoteSourceStatus?
    let textScale:Double
    @ViewBuilder var content:(CGSize)->Content
    var body:some View {
        GeometryReader { geometry in
            let layout=NativeWidgetSourceLayout(height:geometry.size.height,textScale:textScale,source:source)
            let size=CGSize(width:geometry.size.width,height:layout.contentHeight)
            VStack(spacing:0) {
                Group {
                    if layout.showsContent {content(size)}
                    else {Color.clear}
                }.frame(width:size.width,height:size.height).clipped()
                    .opacity(source?.state == .offline || source?.state == .stale ? 0.5 : 1)
                if let warning=source?.warning {
                    Text(warning).font(retroFont(17*textScale)).foregroundStyle(.orange).lineLimit(1)
                        .padding(.horizontal,5).frame(maxWidth:.infinity,alignment:.trailing).frame(height:layout.statusHeight)
                }
            }
        }.help(source.map{"Read-only from \($0.name). "+($0.updatedAt.map{"Updated \($0.formatted(date:.abbreviated,time:.standard))"} ?? "Enable sharing on the source Mac.")} ?? "")
    }
}

enum SharedSourceArtwork {
    static func image(from data:Data?)->NSImage? {
        guard let data,data.count<=SharedMusic.maximumArtworkBytes,
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width),(1...512).contains(height),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {return nil}
        return NSImage(cgImage:image,size:NSSize(width:width,height:height))
    }
}
