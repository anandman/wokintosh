import SwiftUI
import UIKit
import WidgetKit
import WokintoshCore

@MainActor final class PhoneStore:ObservableObject {
    @Published private(set) var snapshot=PhoneSnapshot.empty
    @Published var selectedWidgetID:UUID? {
        didSet {UserDefaults.standard.set(selectedWidgetID?.uuidString,forKey:"selectedPublishedWidget")}
    }
    @Published var selectedSession:PublishedAgentRow? {
        didSet {if selectedSession==nil {selectedRoute=nil;navigationMessage=nil;if oldValue != nil {pendingNavigation=nil}}}
    }
    @Published private(set) var navigationMessage:String?
    @Published var earlierSelection:PhoneWidgetRoute?
    @Published private(set) var performingAction=false
    private var selectedRoute:PhoneRoute?
    private struct NavigationAttempt {let id=UUID();let route:PhoneRoute}
    private var pendingNavigation:NavigationAttempt?
    private var refreshAgain=false
    @Published var message:String?
    @Published private(set) var refreshing=false
    private let repository:PhoneRepository?
    typealias LaunchCompletion = @MainActor @Sendable (Bool)->Void
    typealias SessionLauncher = @MainActor (URL,@escaping LaunchCompletion)->Void
    private let launch:SessionLauncher
    let preview:Bool
    convenience init() {
        #if DEBUG
        let preview=ProcessInfo.processInfo.arguments.contains("--sample-data")
        #else
        let preview=false
        #endif
        do {
            #if DEBUG
            let repository=try preview ? PhoneFixtures.repository() : PhoneRepository.live()
            #else
            let repository=try PhoneRepository.live()
            #endif
            self.init(repository:repository,preview:preview)
        } catch {self.init(repository:nil,preview:preview);message=error.localizedDescription}
    }
    init(repository:PhoneRepository?,preview:Bool=false,launch:SessionLauncher?=nil) {
        self.preview=preview;self.repository=repository
        self.launch=launch ?? {url,completion in UIApplication.shared.open(url,options:[:],completionHandler:completion)}
        do {
            let loaded=try repository?.snapshot() ?? .empty
            snapshot=loaded
        } catch {message=error.localizedDescription}
        selectedWidgetID=UserDefaults.standard.string(forKey:"selectedPublishedWidget").flatMap(UUID.init(uuidString:)) ?? snapshot.feed?.widgets.first?.id
    }
    var selectedWidget:PublishedWidget? {
        snapshot.feed?.widgets.first(where:{$0.id==selectedWidgetID}) ?? snapshot.feed?.widgets.first
    }
    private func apply(_ value:PhoneSnapshot) {
        if snapshot.feed?.publisherID != value.feed?.publisherID {selectedWidgetID=nil}
        snapshot=value
        if let earlier=earlierSelection,!(value.paired && value.feed?.publisherID==earlier.publisherID && value.feed?.widgets.contains(where:{$0.id==earlier.widgetID})==true) {earlierSelection=nil}
        if let pending=pendingNavigation,!(value.paired && value.feed.flatMap{pending.route.resolve(in:$0)} != nil) {pendingNavigation=nil}
        if let route=selectedRoute,value.paired,let feed=value.feed,let row=route.resolve(in:feed) {selectedSession=row}
        else {selectedSession=nil}
        if selectedWidgetID==nil {selectedWidgetID=value.feed?.widgets.first?.id}
    }
    private func readLatest()throws {
        if let repository {apply(try repository.snapshot())}
    }
    func refresh()async {
        guard !preview,let repository else {return}
        if refreshing {refreshAgain=true;return}
        refreshing=true
        repeat {
            refreshAgain=false
            do {
                _=try await repository.refresh()
                // Another operation may have paired/unpaired while the fetch was suspended.
                try readLatest();message=nil
                WidgetCenter.shared.reloadAllTimelines()
            } catch {apply((try? repository.snapshot()) ?? .empty);message=error.localizedDescription}
        } while refreshAgain
        refreshing=false
    }
    func pair(_ text:String) {
        guard let repository,!preview else {return}
        pendingNavigation=nil
        do {
            let pairing=try PhonePairing.decode(Data(text.utf8))
            try repository.pair(pairing);selectedSession=nil;selectedWidgetID=nil
            try readLatest();WidgetCenter.shared.reloadAllTimelines()
            Task {await refresh()}
        } catch {
            // Even a failed pairing transaction may have revoked the previous one.
            selectedSession=nil;apply((try? repository.snapshot()) ?? .empty)
            message="The pairing code could not be saved. Scan the code from Settings → iPhone & iPad on your Mac.\n\n"+error.localizedDescription
        }
    }
    func unpair() {
        guard let repository,!preview else {return}
        pendingNavigation=nil;selectedSession=nil;apply(.empty);selectedWidgetID=nil
        do {try repository.unpair();WidgetCenter.shared.reloadAllTimelines()}
        catch {message=error.localizedDescription}
    }
    func handle(_ url:URL) {
        guard url.scheme=="wokintosh" else {return}
        if url.host=="dashboard" {pendingNavigation=nil;do {try readLatest()} catch {message=error.localizedDescription};return}
        if let route=PhoneWidgetRoute(url:url) {
            pendingNavigation=nil;selectedSession=nil;earlierSelection=nil
            do {try readLatest()} catch {message=error.localizedDescription;return}
            guard snapshot.paired,snapshot.feed?.publisherID==route.publisherID,snapshot.feed?.widgets.contains(where:{$0.id==route.widgetID})==true else {return}
            selectedWidgetID=route.widgetID
            if route.section == .earlier {earlierSelection=route};return
        }
        guard let route=PhoneRoute(url:url) else {return}
        open(route)
    }
    func open(_ row:PublishedAgentRow) {
        guard let publisher=snapshot.feed?.publisherID,let widget=selectedWidget else {return}
        open(PhoneRoute(publisherID:publisher,widgetID:widget.id,rowID:row.id))
    }
    func open(_ route:PhoneRoute) {
        pendingNavigation=nil;selectedSession=nil
        navigate(route)
    }
    func openSelectedSession(backup:Bool=false) {
        guard let route=selectedRoute else {return}
        pendingNavigation=nil
        navigate(route,backup:backup)
    }
    private func navigate(_ route:PhoneRoute,backup:Bool=false) {
        do {try readLatest()}
        catch {pendingNavigation=nil;selectedSession=nil;message=error.localizedDescription;return}
        guard snapshot.paired,let feed=snapshot.feed,let row=route.resolve(in:feed) else {
            selectedSession=nil
            message="This session is no longer in the published widget. Refresh the list on your Mac and this device.";return
        }
        selectedWidgetID=route.widgetID
        let target=row.session.openURLs?.iOS
        guard !preview,let url=backup ? target?.fallbackURL : target?.url else {
            showDetails(row,route:route);return
        }
        let attempt=NavigationAttempt(route:route);pendingNavigation=attempt
        launch(url) { [weak self] opened in self?.finish(attempt,opened:opened,backup:backup) }
    }
    private func finish(_ attempt:NavigationAttempt,opened:Bool,backup:Bool) {
        guard pendingNavigation?.id==attempt.id else {return}
        if opened {pendingNavigation=nil;selectedSession=nil;return}
        do {try readLatest()}
        catch {pendingNavigation=nil;selectedSession=nil;message=error.localizedDescription;return}
        guard pendingNavigation?.id==attempt.id,let feed=snapshot.feed,let row=attempt.route.resolve(in:feed) else {return}
        pendingNavigation=nil
        showDetails(row,route:attempt.route)
        navigationMessage=backup ? "The backup link could not be opened." : "The session’s app could not be opened. You can try the backup below."
    }
    func controlCommand(_ action:AgentControlAction,rowID:String?=nil)->AgentControlCommand? {
        guard snapshot.paired,let feed=snapshot.feed,let widget=selectedWidget,let agents=widget.agents else {return nil}
        let controls:PublishedAgentControls?
        if action == .reviewAllDone {controls=agents.controls}
        else if action == .reviewEarlierDone {controls=agents.earlierControls}
        else {controls=(agents.rows+(agents.earlierRows ?? [])).first(where:{$0.id==rowID})?.controls}
        guard let controls,controls.allowed.contains(action) else {return nil}
        return AgentControlCommand(publisherID:feed.publisherID,widgetID:widget.id,rowID:rowID,action:action,revision:controls.revision)
    }
    func perform(_ action:AgentControlAction,rowID:String?=nil)async {
        guard let command=controlCommand(action,rowID:rowID) else {message=AgentControlError.disabled.localizedDescription;return}
        await perform(command)
    }
    func perform(_ receipt:AgentControlCommand)async {
        guard !preview,!performingAction,let repository else {return}
        var command=receipt;command.id=UUID();command.issuedAt=Date()
        performingAction=true;defer {performingAction=false}
        do {apply(try await repository.perform(command));WidgetCenter.shared.reloadAllTimelines()}
        catch {
            try? readLatest();message=error.localizedDescription
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    func showSessionDetails(_ row:PublishedAgentRow) {
        guard let publisher=snapshot.feed?.publisherID,let widget=selectedWidget else {return}
        let route=PhoneRoute(publisherID:publisher,widgetID:widget.id,rowID:row.id)
        pendingNavigation=nil
        do {try readLatest()} catch {message=error.localizedDescription;return}
        guard snapshot.paired,let feed=snapshot.feed,let latest=route.resolve(in:feed) else {return}
        showDetails(latest,route:route)
    }
    func showEarlierDone() {
        guard let publisher=snapshot.feed?.publisherID,let widget=selectedWidget else {return}
        earlierSelection=PhoneWidgetRoute(publisherID:publisher,widgetID:widget.id)
    }
    private func showDetails(_ row:PublishedAgentRow,route:PhoneRoute) {
        selectedRoute=route;selectedSession=row;navigationMessage=nil
    }
}
