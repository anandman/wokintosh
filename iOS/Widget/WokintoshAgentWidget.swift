import SwiftUI
import WidgetKit
import WokintoshCore

struct AgentTimelineProvider:AppIntentTimelineProvider {
    func placeholder(in context:Context)->AgentWidgetEntry {.example()}
    func snapshot(for configuration:SelectAgentWidgetIntent,in context:Context)async->AgentWidgetEntry {
        if context.isPreview {return .example()}
        let snapshot=(try? PhoneRepository.live().snapshot()) ?? .empty
        return .make(snapshot:snapshot,selection:configuration.widget?.id,at:Date())
    }
    func timeline(for configuration:SelectAgentWidgetIntent,in context:Context)async->Timeline<AgentWidgetEntry> {
        let now=Date()
        let snapshot:PhoneSnapshot
        if let repository=try? PhoneRepository.live(),let refreshed=try? await repository.refresh() {snapshot=refreshed}
        else {snapshot = .empty}
        let entry=AgentWidgetEntry.make(snapshot:snapshot,selection:configuration.widget?.id,at:now)
        var entries=[entry]
        if let agents=entry.widget?.agents {
            let size:PhoneWidgetSize=context.family == .systemLarge ? .large : .medium
            let transitions=[false,true].flatMap {accessibility in
                PhoneWidgetPresentation(agents:agents,size:size,accessibility:accessibility,connection:snapshot.state,at:now).staleTransitions
            }
            for transition in Set(transitions).sorted() {
                var stale=entry;stale.date=transition;entries.append(stale)
            }
        }
        return Timeline(entries:entries,policy:.after(now.addingTimeInterval(900)))
    }
}

@main struct WokintoshAgentWidget:SwiftUI.Widget {
    let kind="dev.wokintosh.phone.agents"
    var body:some WidgetConfiguration {
        AppIntentConfiguration(kind:kind,intent:SelectAgentWidgetIntent.self,provider:AgentTimelineProvider()) {entry in
            AgentWidgetEntryView(entry:entry)
        }
        .configurationDisplayName("Agents")
        .description("Follow Claude Code and Codex sessions across your machines. Tap a session to open its app.")
        .supportedFamilies([.systemMedium,.systemLarge])
    }
}
