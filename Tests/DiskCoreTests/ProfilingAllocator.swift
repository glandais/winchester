import Foundation
@testable import DiskCore

/// Enveloppe un allocateur et chronomètre chacune de ses opérations. Sert à
/// répondre à la seule question qui vaille quand une génération est trop lente :
/// **où** passe le temps.
struct ProfilingAllocator<Wrapped: Allocator>: Allocator {

    var wrapped: Wrapped
    var allocateTime = 0.0
    var extendTime = 0.0
    var freeTime = 0.0
    var noteTime = 0.0
    var allocateCalls = 0
    var noteCalls = 0

    init(_ wrapped: Wrapped) { self.wrapped = wrapped }

    var profile: any FileSystemProfile { wrapped.profile }
    var bitmap: ClusterBitmap { wrapped.bitmap }

    mutating func allocate(clusterCount: UInt32, hint: AllocationHint) -> [Extent] {
        let start = Date()
        defer { allocateTime += Date().timeIntervalSince(start); allocateCalls += 1 }
        return wrapped.allocate(clusterCount: clusterCount, hint: hint)
    }

    @discardableResult
    mutating func extend(file: inout FileEntry, byClusters count: UInt32) -> Bool {
        let start = Date()
        defer { extendTime += Date().timeIntervalSince(start) }
        return wrapped.extend(file: &file, byClusters: count)
    }

    mutating func free(_ extents: [Extent]) {
        let start = Date()
        defer { freeTime += Date().timeIntervalSince(start) }
        wrapped.free(extents)
    }

    @discardableResult
    mutating func claim(_ extent: Extent) -> Bool {
        wrapped.claim(extent)
    }

    mutating func noteFileCreated(logicalSize: UInt64) {
        let start = Date()
        defer { noteTime += Date().timeIntervalSince(start); noteCalls += 1 }
        wrapped.noteFileCreated(logicalSize: logicalSize)
    }

    var report: String {
        String(format: "allocate %.2f s (%d appels) · extend %.2f s · free %.2f s · MFT %.2f s (%d appels)",
               allocateTime, allocateCalls, extendTime, freeTime, noteTime, noteCalls)
    }
}
