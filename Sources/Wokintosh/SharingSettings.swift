import SwiftUI
import WokintoshCore

struct SourceSharingSettings:View {
    @ObservedObject var store:DashboardStore
    @ObservedObject var sharing:SourceSharing
    var body:some View {
        Section("Share from this Mac") {
            Toggle("Share Now Playing",isOn:option(\.shareMusic))
            Toggle("Share selected calendars",isOn:option(\.shareCalendar))
            if sharing.options.shareCalendar {
                if !store.native.calendar.authorized {
                    Text("Connect Calendar above, then choose the calendars to share. No calendars are shared until you select them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let calendars=store.native.calendar.calendars
                let selected=sharing.options.calendarIDs
                if !calendars.isEmpty || !selected.isEmpty {
                    SettingsInventoryScrollView(identifier:"sharedCalendarInventory",accessibilityLabel:"Calendars shared from this Mac",
                        items:calendars.map {calendar in
                            SettingsInventoryItem(id:calendar.id,title:calendar.title,subtitle:calendar.sourceTitle,isSelected:selected.contains(calendar.id))
                        }+selected.filter{id in !calendars.contains{$0.id == id}}.map {id in
                            SettingsInventoryItem(id:id,title:"Unavailable calendar",subtitle:"Remove this selection to stop sharing it",isSelected:true)
                        },onToggle:{id,on in
                            var options=sharing.options;options.calendarIDs.removeAll{$0 == id}
                            if on {options.calendarIDs.append(id)}
                            store.setSharingOptions(options)
                        }).frame(height:160)
                }
                if selected.isEmpty {Text("No calendars selected for sharing").font(.caption).foregroundStyle(.orange)}
                Text("Shares upcoming event titles and times for the next seven days. Notes, attendees, locations, and links stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(sharing.status).font(.caption).foregroundStyle(.secondary)
            Text("Keep Wokintosh running on this Mac; its dashboard can be closed. On another Mac, connect this machine in Machines, then select it in a Now Playing or Calendar widget.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Anyone using your SSH account on this Mac can read sources you share. Sharing choices stay on this Mac and are excluded from exported setups and templates.")
                .font(.caption).foregroundStyle(.secondary)
            if store.document.previewMode {Text("Sharing is paused in Preview.").font(.caption).foregroundStyle(.orange)}
        }.disabled(store.document.previewMode)
    }
    private func option(_ key:WritableKeyPath<SourceSharingOptions,Bool>)->Binding<Bool> {
        Binding(get:{sharing.options[keyPath:key]},set:{value in
            var options=sharing.options;options[keyPath:key]=value;store.setSharingOptions(options)
        })
    }
}

struct MusicWidgetSettings:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        let presentation=store.musicSource(for:widget)
        Form {
            Section("Apple Music") {
                WidgetMachinePicker(store:store,widget:widget)
                if let source=presentation.source {
                    Text("Read-only from \(source.name)").font(.callout)
                    if let warning=source.warning {Text(warning).foregroundStyle(.orange)}
                    Text(presentation.info.status).foregroundStyle(.secondary)
                    Text("Enable Share Now Playing in Wokintosh’s Connections settings on that Mac, and install its 1.3 collector in Machines.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Manage Machines…") {store.openSettings(.machines)}
                } else {
                    ConnectionStatusLabel(connected:store.native.musicConnected,known:store.native.musicConnectionKnown)
                    Text(store.native.music.status).foregroundStyle(.secondary)
                    if !store.native.music.artworkStatus.isEmpty {Text(store.native.music.artworkStatus).font(.caption).foregroundStyle(.secondary)}
                    Button("Manage Connections…") {store.openSettings(.connections)}
                }
            }
            Section {
                Text("Shows the selected Mac’s current track and album artwork. Playback controls are available for This Mac; remote sources are read-only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
