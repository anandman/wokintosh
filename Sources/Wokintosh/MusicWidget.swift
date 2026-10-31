import SwiftUI
import WokintoshCore

struct MusicWidget: View {
    @ObservedObject var store:DashboardStore
    var body:some View {
        GeometryReader { geometry in
            let music=store.native.music
            let preview=store.document.previewMode
            let t=store.document.textScale
            if preview || music.hasTrack {
                let stacked=geometry.size.width/t<300 && geometry.size.height/t>=160
                let compact=geometry.size.height/t<(stacked ? 440 : 260)
                let padding=compact ? 6.0 : 12.0
                let spacing=compact ? 12.0 : 16.0
                let artSize=max(25,stacked
                    ? min(geometry.size.width-2*padding,geometry.size.height-2*padding-(compact ? 106 : 250)*t-8)
                    : min(geometry.size.height-2*padding,geometry.size.width*0.43))
                let detailWidth=geometry.size.width-2*padding-(stacked ? 0 : artSize+spacing)
                let showArtist=stacked || geometry.size.height/t>=75
                let inlineControls=compact && !stacked && detailWidth/t>=260 && showArtist
                let separateControls = !compact || stacked || (geometry.size.height/t>=108 && detailWidth/t>=150)
                let showProgress = !compact || (!stacked && geometry.size.height/t>=155 && detailWidth/t>=180)
                Group {
                    if stacked {
                        VStack(spacing:8) {
                            artwork(preview:preview,url:music.artworkURL).frame(width:artSize,height:artSize)
                            details(preview:preview,compact:compact,t:t,showArtist:showArtist,inlineControls:false,separateControls:separateControls,showProgress:showProgress)
                        }
                    } else {
                        HStack(spacing:spacing) {
                            artwork(preview:preview,url:music.artworkURL).frame(width:artSize,height:artSize)
                            details(preview:preview,compact:compact,t:t,showArtist:showArtist,inlineControls:inlineControls,separateControls:separateControls,showProgress:showProgress)
                        }
                    }
                }.padding(padding).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                VStack(alignment:.leading,spacing:10) {
                    Text("Now Playing").font(retroFont(30*t))
                    Text(music.status).font(retroFont(22*t,bold:false))
                    if !store.native.musicEnabled { Button("Source settings…") { store.openSettings(.connections) }.buttonStyle(.bordered) }
                }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
    @ViewBuilder private func artwork(preview:Bool,url:URL?)->some View {
        if preview, let file=Bundle.module.url(forResource:"preview-artwork",withExtension:"png"),let image=NSImage(contentsOf:file) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else if let url,let image=NSImage(contentsOf:url) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else { Rectangle().fill(Color.retroPurple.opacity(0.22)).overlay(Image(systemName:"music.note").font(.system(size:48)).foregroundStyle(Color.retroPurple)).help(store.native.music.artworkStatus.isEmpty ? "No artwork provided by Apple Music" : store.native.music.artworkStatus) }
    }
    private func details(preview:Bool,compact:Bool,t:Double,showArtist:Bool,inlineControls:Bool,separateControls:Bool,showProgress:Bool)->some View {
        let title=preview ? "Blue Hour" : store.native.music.title
        let artist=preview ? "Paper Satellites" : store.native.music.artist
        return VStack(alignment:.leading,spacing:compact ? 4 : 8) {
            Text(title).font(retroFont((compact ? 27 : 32)*t)).lineLimit(compact ? 1 : 2).help(title)
            if inlineControls {
                HStack(spacing:4) {
                    Text(artist).font(retroFont(20*t,bold:false)).lineLimit(1).help(artist)
                    Spacer(minLength:4)
                    playbackControls(preview:preview,t:t,compact:true)
                }
            } else if showArtist {
                Text(artist).font(retroFont((compact ? 20 : 23)*t,bold:false)).lineLimit(1).help(artist)
            }
            if showProgress {
                if !compact { Spacer(minLength:4) }
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let m=store.native.music
                    let position=preview ? 137.0 : min(m.duration,max(0,m.position+(m.isPlaying ? context.date.timeIntervalSince(m.updatedAt) : 0)))
                    let duration=preview ? 253.0 : m.duration
                    VStack(alignment:.leading,spacing:3) {
                        RetroProgress(fraction:duration>0 ? position/duration : 0,tint:.retroPurple).frame(height:compact ? 7 : 13)
                        Text("\(clockTime(position)) / \(clockTime(duration))").font(retroFont(17*t,bold:false)).monospacedDigit()
                    }
                }
            }
            if separateControls && !inlineControls { playbackControls(preview:preview,t:t,compact:compact) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
    }
    private func playbackControls(preview:Bool,t:Double,compact:Bool)->some View {
        HStack(spacing:(compact ? 6 : 12)*t) {
            playback("backward.end.fill",action:"previous",label:"Previous track",t:t,compact:compact)
            playback(store.native.music.isPlaying || preview ? "pause.fill" : "play.fill",action:"playpause",label:store.native.music.isPlaying || preview ? "Pause" : "Play",t:t,compact:compact)
            playback("forward.end.fill",action:"next",label:"Next track",t:t,compact:compact)
        }.fixedSize()
    }
    private func playback(_ symbol:String,action:String,label:String,t:Double,compact:Bool)->some View {
        Button { if !store.document.previewMode { Task { await store.native.performPlayback(action) } } } label: {
            Image(systemName:symbol).font(.system(size:(compact ? 18 : 22)*t,weight:.bold))
                .frame(width:28*t,height:28*t).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
    private func clockTime(_ value:Double)->String { let n=Int(value.isFinite ? max(0,value) : 0);return String(format:"%d:%02d",n/60,n%60) }
}
