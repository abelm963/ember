import SwiftUI
import UIKit

/// Loads and keeps artwork. Images are kept in memory while the app runs and on disk
/// between launches, so rows scroll smoothly and Home opens instantly the second time.
final class ImageStore {
    static let shared = ImageStore()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var running: [URL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        memory.totalCostLimit = 300 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        lock.lock()
        if let task = running[url] {
            lock.unlock()
            return await task.value
        }
        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = UIImage(data: data) else { return nil }
            // Decode now, off the main thread, so scrolling never stutters.
            return img.preparingForDisplay() ?? img
        }
        running[url] = task
        lock.unlock()
        let img = await task.value
        lock.lock()
        running[url] = nil
        lock.unlock()
        if let img {
            memory.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
        }
        return img
    }

    /// Starts loading images that are about to be needed.
    func warm(_ urls: [URL?]) async {
        await withTaskGroup(of: Void.self) { group in
            for case let url? in urls { group.addTask { _ = await self.image(url) } }
        }
    }
}

/// An image from the network that fills its frame, with a quiet placeholder while it loads.
struct RemoteImage<Fallback: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: alignment) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .transition(.opacity)
            } else if failed || url == nil {
                fallback()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .clipped()
        .task(id: url) {
            failed = false
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageStore.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            let img = await ImageStore.shared.image(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                image = img
                failed = img == nil
            }
        }
    }
}

extension RemoteImage where Fallback == Color {
    init(_ url: URL?, contentMode: ContentMode = .fill, alignment: Alignment = .center) {
        self.init(url: url, contentMode: contentMode, alignment: alignment) { C.surface2 }
    }
}
