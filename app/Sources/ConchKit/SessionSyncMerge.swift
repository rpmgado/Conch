import Foundation

/// 相对于上次共同版本合并：未改的字段采用同步目录里的值，改过的字段保留本机值。
/// 同一字段双方都改过时记录冲突，由持久层保存双方快照，不能静默丢弃。
public struct SessionSyncMerge {
    public let library: SessionLibrary
    public let hasConflicts: Bool

    public init(base: SessionLibrary, local: SessionLibrary, remote: SessionLibrary) {
        var conflict = false
        func choose<T: Equatable>(_ old: T, _ ours: T, _ theirs: T) -> T {
            if ours == old { return theirs }
            if theirs != old && ours != theirs { conflict = true }
            return ours
        }
        let old = base.sessions.reduce(into: [UUID: SessionProfile]()) { $0[$1.id] = $1 }
        let ours = local.sessions.reduce(into: [UUID: SessionProfile]()) { $0[$1.id] = $1 }
        let theirs = remote.sessions.reduce(into: [UUID: SessionProfile]()) { $0[$1.id] = $1 }
        var result = remote
        result.sessions = []
        var seen = Set<UUID>()
        for id in (remote.sessions + local.sessions).map(\.id) where seen.insert(id).inserted {
            let b = old[id], l = ours[id], r = theirs[id]
            let value: SessionProfile?
            if l == b { value = r }
            else if r == b || l == r { value = l }
            else if let b, let l, let r {
                var merged = r
                func field<T: Equatable>(_ key: WritableKeyPath<SessionProfile, T>) {
                    merged[keyPath: key] = choose(b[keyPath: key], l[keyPath: key], r[keyPath: key])
                }
                field(\.kind); field(\.serial); field(\.name); field(\.group)
                field(\.host); field(\.port); field(\.username); field(\.auth)
                field(\.keyPaths); field(\.identitiesOnly); field(\.identityAgent)
                field(\.legacyAlgorithms); field(\.jumpHostID); field(\.autoReconnect)
                field(\.logSession); field(\.encoding); field(\.forwards); field(\.notes)
                merged.lastConnected = [l.lastConnected, r.lastConnected].compactMap { $0 }.max()
                value = merged
            } else {
                // 删除和编辑冲突、或者同 ID 独立新增：本机操作生效，另一份由持久层备份。
                conflict = true
                value = l
            }
            if let value { result.sessions.append(value) }
        }
        let deleted = Set(old.keys).subtracting(result.sessions.map(\.id))
        for i in result.sessions.indices where result.sessions[i].jumpHostID.map(deleted.contains) == true {
            result.sessions[i].jumpHostID = nil
        }
        let removedGroups = Set(base.groups).subtracting(local.groups)
        result.groups = Set(remote.groups).subtracting(removedGroups).union(Set(local.groups).subtracting(base.groups)).sorted()
        for key in Set(base.environments.keys).union(local.environments.keys).union(remote.environments.keys) {
            result.environments[key] = choose(base.environments[key], local.environments[key], remote.environments[key])
        }
        library = result
        hasConflicts = conflict
    }
}
