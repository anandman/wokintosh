import AppIntents
import WidgetKit
import WokintoshCore

/// Only the publishing Mac can validate and commit this receipt-checked action.
struct PerformAgentControlIntent:AppIntent {
    static var title:LocalizedStringResource="Update Agent notice"
    static var description=IntentDescription("Review a Done notice or update Wokintosh’s manual Blocked status.")
    static var openAppWhenRun=false
    static var isDiscoverable=false
    @Parameter(title:"Action receipt") var receipt:String
    init() {}
    init(receipt:String) {self.receipt=receipt}
    func perform()async throws->some IntentResult {
        defer {WidgetCenter.shared.reloadAllTimelines()}
        var command=try AgentControlCommand.decode(Data(receipt.utf8))
        command.issuedAt=Date();command.id=UUID()
        _=try await PhoneRepository.live().perform(command)
        return .result()
    }
}
