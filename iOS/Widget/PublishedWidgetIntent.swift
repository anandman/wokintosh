import AppIntents
import WokintoshCore

struct PublishedWidgetEntity:AppEntity {
    let id:String
    let name:String
    static var typeDisplayRepresentation:TypeDisplayRepresentation="Agent widget"
    static var defaultQuery=PublishedWidgetQuery()
    var displayRepresentation:DisplayRepresentation {DisplayRepresentation(title:"\(name)")}
}

struct PublishedWidgetQuery:EntityQuery {
    private func available()->[PublishedWidgetEntity] {
        guard let repository=try? PhoneRepository.live(),let snapshot=try? repository.snapshot(),let feed=snapshot.feed else {return []}
        return feed.widgets.map {PublishedWidgetEntity(id:AgentWidgetEntry.scopedID(publisher:feed.publisherID,widget:$0.id),name:$0.name)}
    }
    func entities(for identifiers:[String])async throws->[PublishedWidgetEntity] {
        let requested=Set(identifiers);return available().filter{requested.contains($0.id)}
    }
    func suggestedEntities()async throws->[PublishedWidgetEntity] {available()}
    func defaultResult()async->PublishedWidgetEntity? {available().first}
}

struct SelectAgentWidgetIntent:WidgetConfigurationIntent {
    static var title:LocalizedStringResource="Agent widget"
    static var description=IntentDescription("Choose an Agent widget published by your Mac.")
    @Parameter(title:"Published widget") var widget:PublishedWidgetEntity?
}
