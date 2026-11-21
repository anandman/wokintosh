import Foundation

public enum PhoneFetchError:Error,Equatable,LocalizedError {
    case unauthorized,unavailable,oversized,invalidResponse
    public var errorDescription:String? {
        switch self {
        case .unauthorized:return "Pair this iPhone again to restore access."
        case .unavailable:return "The publishing Mac could not be reached."
        case .oversized:return "The publishing Mac sent too much data."
        case .invalidResponse:return "The publishing Mac sent an unreadable response."
        }
    }
}

public final class PhoneFeedClient:@unchecked Sendable {
    private let configuration:URLSessionConfiguration
    public init(configuration:URLSessionConfiguration = .ephemeral) {
        self.configuration=configuration.copy() as! URLSessionConfiguration
        self.configuration.urlCache=nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.timeoutIntervalForRequest=15
        self.configuration.timeoutIntervalForResource=20
        self.configuration.httpShouldSetCookies=false
    }
    public func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {
        var request=URLRequest(url:pairing.endpointURL)
        request.setValue("Bearer "+pairing.token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        return try await send(request,command:false)
    }
    public func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {
        var request=URLRequest(url:pairing.endpointURL.deletingLastPathComponent().appendingPathComponent("agent-actions"))
        request.httpMethod="POST";request.httpBody=try command.encoded()
        request.setValue("Bearer "+pairing.token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        return try await send(request,command:true)
    }
    private func send(_ request:URLRequest,command:Bool)async throws->PublishedWidgetFeed {
        let operation=PhoneFetchOperation(command:command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {continuation in
                operation.start(request,configuration:configuration,continuation:continuation)
            }
        } onCancel: {operation.cancel()}
    }
}

/// Stream into a bounded buffer. URLSession's data(for:) would allocate the whole
/// response before a size check, and redirects must never forward the access key.
private final class PhoneFetchOperation:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    private let command:Bool
    init(command:Bool) {self.command=command;super.init()}
    private let lock=NSLock()
    private var continuation:CheckedContinuation<PublishedWidgetFeed,Error>?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var bytes=Data()
    private var cancelled=false
    func start(_ request:URLRequest,configuration:URLSessionConfiguration,continuation:CheckedContinuation<PublishedWidgetFeed,Error>) {
        lock.lock()
        self.continuation=continuation
        if cancelled {lock.unlock();finish(.failure(CancellationError()));return}
        let session=URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
        let task=session.dataTask(with:request)
        self.session=session;self.task=task
        lock.unlock();task.resume()
    }
    func cancel() {
        lock.lock();cancelled=true;lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result:Result<PublishedWidgetFeed,Error>) {
        lock.lock()
        guard let continuation else {lock.unlock();return}
        self.continuation=nil
        let session=self.session;self.session=nil;task=nil;bytes=Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with:result)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        completionHandler(nil)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse else {completionHandler(.cancel);finish(.failure(PhoneFetchError.invalidResponse));return}
        guard http.statusCode==200 else {
            completionHandler(.cancel)
            if command && [403,405].contains(http.statusCode) {finish(.failure(AgentControlError.disabled))}
            else if command && http.statusCode==409 {finish(.failure(AgentControlError.conflict))}
            else {finish(.failure([401,403].contains(http.statusCode) ? PhoneFetchError.unauthorized : .unavailable))};return
        }
        guard response.expectedContentLength<=PublishedWidgetFeed.maximumBytes else {completionHandler(.cancel);finish(.failure(PhoneFetchError.oversized));return}
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock()
        guard continuation != nil else {lock.unlock();return}
        guard data.count<=PublishedWidgetFeed.maximumBytes-bytes.count else {lock.unlock();finish(.failure(PhoneFetchError.oversized));return}
        bytes.append(data);lock.unlock()
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if let error {finish(.failure(error));return}
        lock.lock();let data=bytes;lock.unlock()
        do {finish(.success(try PublishedWidgetFeed.decode(data)))} catch {finish(.failure(error))}
    }
}
