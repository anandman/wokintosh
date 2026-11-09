import SwiftUI
import WokintoshCore

struct MusicWidget: View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var actionsEnabled=true
    var body:some View {
        let presentation=store.musicSource(for:widget)
        NativeWidgetSourceFrame(source:presentation.source,textScale:store.document.textScale) { size in
            musicContent(size:size,presentation:presentation)
        }
    }
    @ViewBuilder private func musicContent(size:CGSize,presentation:MusicSourcePresentation)->some View {
        let music=presentation.info
        let preview=store.document.previewMode
        let t=store.document.textScale
        if preview || music.hasTrack {
            if size.height<32*t+12 {
                Text(music.title).font(retroFont(20*t)).lineLimit(1).padding(.horizontal,6)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).help(music.title+" · "+music.artist)
            } else {
            let stacked=size.width/t<300 && size.height/t>=160
            let compact=size.height/t<(stacked ? 440 : 260)
            let padding=compact ? 6.0 : 12.0
            let spacing=compact ? 12.0 : 16.0
            let artSize=max(25,stacked
                ? min(size.width-2*padding,size.height-2*padding-(compact ? 106 : 250)*t-8)
                : min(size.height-2*padding,size.width*0.43))
            let detailWidth=size.width-2*padding-(stacked ? 0 : artSize+spacing)
            let showArtist=stacked || size.height/t>=75
            let controlsBelow=compact && !stacked && size.height>=12+85*t && detailWidth/t>=100
            let inlineControls=compact && !stacked && !controlsBelow && detailWidth/t>=260 && showArtist
            let separateControls = !compact || stacked || controlsBelow || (size.height/t>=108 && detailWidth/t>=150)
            let showProgress = !compact || (!stacked && size.height/t>=155 && detailWidth/t>=180)
            Group {
                if stacked {
                    VStack(spacing:8) {
                        WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled,accessibilityName:"Open Now Playing action") {artwork(preview:preview,info:music).frame(width:artSize,height:artSize)}
                        details(preview:preview,presentation:presentation,compact:compact,t:t,showArtist:showArtist,inlineControls:false,separateControls:separateControls,showProgress:showProgress)
                    }
                } else {
                    HStack(spacing:spacing) {
                        WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled,accessibilityName:"Open Now Playing action") {artwork(preview:preview,info:music).frame(width:artSize,height:artSize)}
                        details(preview:preview,presentation:presentation,compact:compact,t:t,showArtist:showArtist,inlineControls:inlineControls,separateControls:separateControls,showProgress:showProgress)
                    }
                }
            }.padding(padding).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        } else {
            VStack(alignment:.leading,spacing:10) {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                    VStack(alignment:.leading,spacing:10) {
                        if size.height/t>120 {Text("Now Playing").font(retroFont(30*t))}
                        Text(music.status).font(retroFont(20*t,bold:false)).lineLimit(size.height/t>100 ? 2 : 1)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if size.height/t>110 && presentation.source != nil {Button("Manage Machines…") {store.openSettings(.machines)}.buttonStyle(.bordered)}
                else if size.height/t>110 && !store.native.musicEnabled {Button("Source settings…") {store.openSettings(.connections)}.buttonStyle(.bordered)}
            }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }
    }
    @ViewBuilder private func artwork(preview:Bool,info:NowPlayingInfo)->some View {
        if preview, let file=Bundle.module.url(forResource:"preview-artwork",withExtension:"png"),let image=NSImage(contentsOf:file) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else if let image=SharedSourceArtwork.image(from:info.artworkData) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else if let url=info.artworkURL,let image=NSImage(contentsOf:url) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else { Rectangle().fill(Color.retroPurple.opacity(0.22)).overlay(Image(systemName:"music.note").font(.system(size:48)).foregroundStyle(Color.retroPurple)).help(info.artworkStatus.isEmpty ? "No artwork provided by the source" : info.artworkStatus) }
    }
    private func details(preview:Bool,presentation:MusicSourcePresentation,compact:Bool,t:Double,showArtist:Bool,inlineControls:Bool,separateControls:Bool,showProgress:Bool)->some View {
        let title=preview ? "Blue Hour" : presentation.info.title
        let artist=preview ? "Paper Satellites" : presentation.info.artist
        return VStack(alignment:.leading,spacing:compact && separateControls && !inlineControls ? 1 : (compact ? 4 : 8)) {
            if inlineControls {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                    Text(title).font(retroFont((compact ? 27 : 32)*t)).lineLimit(compact ? 1 : 2).help(title).frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack(spacing:4) {
                    WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                        Text(artist).font(retroFont(20*t,bold:false)).lineLimit(1).help(artist)
                    }
                    Spacer(minLength:4)
                    playbackControls(preview:preview,presentation:presentation,t:t,compact:true)
                }
            } else {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                    VStack(alignment:.leading,spacing:compact && separateControls ? 1 : (compact ? 4 : 8)) {
                        Text(title).font(retroFont((compact ? 27 : 32)*t)).lineLimit(compact ? 1 : 2).help(title)
                        if showArtist {Text(artist).font(retroFont((compact ? 20 : 23)*t,bold:false)).lineLimit(1).help(artist)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            if showProgress {
                if !compact { Spacer(minLength:4) }
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let m=store.musicSource(for:widget,at:context.date).info
                    let position=preview ? 137.0 : min(m.duration,max(0,m.position+(m.isPlaying ? context.date.timeIntervalSince(m.updatedAt) : 0)))
                    let duration=preview ? 253.0 : m.duration
                    VStack(alignment:.leading,spacing:3) {
                        RetroProgress(fraction:duration>0 ? position/duration : 0,tint:.retroPurple).frame(height:compact ? 7 : 13)
                        Text("\(clockTime(position)) / \(clockTime(duration))").font(retroFont(17*t,bold:false)).monospacedDigit()
                    }
                }
            }
            if separateControls && !inlineControls { playbackControls(preview:preview,presentation:presentation,t:t,compact:compact) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
    }
    @ViewBuilder private func playbackControls(preview:Bool,presentation:MusicSourcePresentation,t:Double,compact:Bool)->some View {
        if !presentation.allowsPlayback {
            Text(presentation.source?.state == .ready ? (presentation.info.isPlaying ? "Playing · Read-only" : "Paused · Read-only") : "Read-only")
                .font(retroFont(17*t,bold:false)).lineLimit(1)
        } else { HStack(spacing:(compact ? 6 : 12)*t) {
            playback("backward.end.fill",action:"previous",label:"Previous track",t:t,compact:compact)
            playback(presentation.info.isPlaying || preview ? "pause.fill" : "play.fill",action:"playpause",label:presentation.info.isPlaying || preview ? "Pause" : "Play",t:t,compact:compact)
            playback("forward.end.fill",action:"next",label:"Next track",t:t,compact:compact)
        }.fixedSize() }
    }
    private func playback(_ symbol:String,action:String,label:String,t:Double,compact:Bool)->some View {
        Button { if !store.document.previewMode { Task { await store.performPlayback(action,for:widget.id) } } } label: {
            Image(systemName:symbol).font(.system(size:(compact ? 18 : 22)*t,weight:.bold))
                .frame(width:28*t,height:28*t).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
    private func clockTime(_ value:Double)->String { let n=Int(value.isFinite ? max(0,value) : 0);return String(format:"%d:%02d",n/60,n%60) }
}
