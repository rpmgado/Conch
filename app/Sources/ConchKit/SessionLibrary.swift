import Foundation

/// 所有保存的会话和分组。纯数据，持久化由 App 里的 SessionStore 负责。
public struct SessionLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var sessions: [SessionProfile] = []
    /// 显式创建的分组（包括还没有会话的空分组）
    public var groups: [String] = []
    /// 分组的环境标签，键是分组路径；下级分组没设时跟着上级
    public var environments: [String: SessionEnvironment] = [:]

    public init(sessions: [SessionProfile] = [], groups: [String] = [], environments: [String: SessionEnvironment] = [:]) {
        self.sessions = sessions
        self.groups = groups
        self.environments = environments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try c.decodeIfPresent([SessionProfile].self, forKey: .sessions) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        // 新版本加的环境标签：不认识的值（以后加的种类）跳过，不让整个文件读不出来
        let raw = try c.decodeIfPresent([String: String].self, forKey: .environments) ?? [:]
        environments = raw.compactMapValues(SessionEnvironment.init(rawValue:))
    }

    // MARK: 环境标签

    /// 分组的环境：自己没设就看上级
    public func environment(ofGroup path: String) -> SessionEnvironment? {
        var current = GroupPath.normalize(path)
        while !current.isEmpty {
            if let environment = environments[current] { return environment }
            current = GroupPath.parent(of: current)
        }
        return nil
    }

    public func environment(of profile: SessionProfile) -> SessionEnvironment? {
        environment(ofGroup: profile.group)
    }

    /// 给分组设环境标签；nil 表示清掉（跟着上级）
    public mutating func setEnvironment(_ environment: SessionEnvironment?, forGroup path: String) {
        let path = GroupPath.normalize(path)
        guard !path.isEmpty else { return }
        environments[path] = environment
        if environment != nil { addGroup(path) }
    }

    // MARK: 查询

    public func session(_ id: UUID?) -> SessionProfile? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// 所有分组（显式创建的 + 会话用到的 + 它们的上级），排好序
    public var allGroups: [String] {
        var set = Set<String>()
        for path in groups + sessions.map(\.group) where !path.isEmpty {
            set.formUnion(GroupPath.ancestors(of: path))
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 按名称、主机、用户名、分组、备注搜索
    public func search(_ query: String) -> [SessionProfile] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sortedSessions(sessions) }
        let matches = sessions.filter { session in
            let haystack = [session.displayName, session.host, session.username, session.group, session.notes,
                            "\(session.username)@\(session.host)"]
                .joined(separator: " ")
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return sortedSessions(matches)
    }

    /// 最近连接过的会话，新的在前
    public func recent(limit: Int) -> [SessionProfile] {
        Array(
            sessions
                .filter { $0.lastConnected != nil }
                .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
                .prefix(limit)
        )
    }

    /// 可以当某个会话跳板机的候选：排除它自己，以及会形成循环的
    public func jumpCandidates(for id: UUID) -> [SessionProfile] {
        sortedSessions(sessions.filter { candidate in
            candidate.id != id && !chainContains(start: candidate.id, target: id)
        })
    }

    private func chainContains(start: UUID, target: UUID) -> Bool {
        var seen = Set<UUID>()
        var current: UUID? = start
        while let id = current, seen.insert(id).inserted {
            if id == target { return true }
            current = session(id)?.jumpHostID
        }
        return false
    }

    public enum ChainError: Error, Equatable, CustomStringConvertible {
        case missingJumpHost(String)
        case cycle(String)

        public var description: String {
            switch self {
            case .missingJumpHost(let name): "“\(name)”设置的跳板机已经被删除了，请重新选择"
            case .cycle(let name): "“\(name)”的跳板机设置形成了循环"
            }
        }
    }

    /// 连接某个会话要经过的跳板机，最外层（最先连接的）在前，不含会话自己
    public func jumpChain(for profile: SessionProfile) throws -> [SessionProfile] {
        var chain: [SessionProfile] = []
        var seen: Set<UUID> = [profile.id]
        var current = profile
        while let jumpID = current.jumpHostID {
            guard let jump = session(jumpID) else { throw ChainError.missingJumpHost(current.displayName) }
            guard seen.insert(jump.id).inserted else { throw ChainError.cycle(profile.displayName) }
            chain.insert(jump, at: 0)
            current = jump
        }
        return chain
    }

    // MARK: 修改

    public mutating func upsert(_ profile: SessionProfile) {
        var profile = profile
        profile.group = GroupPath.normalize(profile.group)
        if let index = sessions.firstIndex(where: { $0.id == profile.id }) {
            sessions[index] = profile
        } else {
            sessions.append(profile)
        }
    }

    /// 删除会话；把其他会话指向它们的跳板机设置一并清掉
    public mutating func remove(ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        for index in sessions.indices where sessions[index].jumpHostID.map(ids.contains) == true {
            sessions[index].jumpHostID = nil
        }
    }

    public mutating func markConnected(_ id: UUID, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].lastConnected = date
    }

    public mutating func addGroup(_ path: String) {
        let path = GroupPath.normalize(path)
        guard !path.isEmpty, !groups.contains(path) else { return }
        groups.append(path)
    }

    /// 改分组名（连同下级分组和里面的会话）。新名字已存在时会合并进去
    public mutating func renameGroup(_ old: String, to new: String) {
        let old = GroupPath.normalize(old)
        let new = GroupPath.normalize(new)
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        func moved(_ path: String) -> String {
            guard GroupPath.isWithin(path, old) else { return path }
            return new + path.dropFirst(old.count)
        }
        groups = Array(Set(groups.map(moved)))
        for index in sessions.indices {
            sessions[index].group = moved(sessions[index].group)
        }
        // 环境标签跟着搬；合并进已有分组时以那边原来的为准
        var updated = environments.filter { !GroupPath.isWithin($0.key, old) }
        for (path, environment) in environments where GroupPath.isWithin(path, old) && updated[moved(path)] == nil {
            updated[moved(path)] = environment
        }
        environments = updated
    }

    /// 删除分组：里面的会话和下级分组都挪到上一级，不会丢会话
    public mutating func removeGroup(_ path: String) {
        let path = GroupPath.normalize(path)
        guard !path.isEmpty else { return }
        let parent = GroupPath.parent(of: path)
        func lifted(_ child: String) -> String {
            guard GroupPath.isWithin(child, path) else { return child }
            if child == path { return parent }
            return GroupPath.join(parent, String(child.dropFirst(path.count + 1)))
        }
        groups = Array(Set(groups.filter { $0 != path }.map(lifted))).filter { !$0.isEmpty }
        for index in sessions.indices {
            sessions[index].group = lifted(sessions[index].group)
        }
        // 删掉的分组自己的标签不要了；下级分组的标签跟着挪到上一级（和已有的冲突时以已有的为准）
        var updated = environments.filter { !GroupPath.isWithin($0.key, path) }
        for (child, environment) in environments where GroupPath.isWithin(child, path) && child != path {
            let target = lifted(child)
            if !target.isEmpty, updated[target] == nil { updated[target] = environment }
        }
        environments = updated
    }

    public mutating func move(ids: Set<UUID>, to group: String) {
        let group = GroupPath.normalize(group)
        for index in sessions.indices where ids.contains(sessions[index].id) {
            sessions[index].group = group
        }
        if !group.isEmpty { addGroup(group) }
    }

    /// 合并导入的会话：同一分组里名称、地址都相同的视为重复，跳过。
    /// 导入的会话之间用 jumpHostID 互相引用时，被跳过的那些会改指向已有的同一个会话。
    /// 打开同步时把本机的会话并进同步文件夹里的：同一个会话（id 相同）以同步文件夹里的为准；
    /// 两边各自导入过的同一台服务器（名称、分组、地址都一样）不重复添加；分组取并集
    public mutating func absorb(_ other: SessionLibrary) {
        let known = Set(sessions.map(\.id))
        merge(other.sessions.filter { !known.contains($0.id) })
        for group in other.groups where !groups.contains(group) {
            addGroup(group)
        }
        for (path, environment) in other.environments where environments[path] == nil {
            environments[path] = environment
        }
    }

    @discardableResult
    public mutating func merge(_ imported: [SessionProfile]) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        var replacement: [UUID: UUID] = [:]
        var toAdd: [SessionProfile] = []
        for profile in imported {
            let group = GroupPath.normalize(profile.group)
            if let existing = sessions.first(where: {
                $0.group == group && $0.displayName == profile.displayName && $0.endpointKey == profile.endpointKey
            }) {
                replacement[profile.id] = existing.id
                skipped += 1
            } else {
                toAdd.append(profile)
            }
        }
        for var profile in toAdd {
            if let jump = profile.jumpHostID, let mapped = replacement[jump] {
                profile.jumpHostID = mapped
            }
            upsert(profile)
            added += 1
        }
        return (added, skipped)
    }

    // MARK: 树

    /// 侧边栏用的树：分组在前、会话在后，都按名称排序
    public func tree() -> [SessionNode] {
        children(of: "")
    }

    private func children(of parent: String) -> [SessionNode] {
        let childGroups = allGroups.filter { GroupPath.parent(of: $0) == parent }
        let groupNodes = childGroups.map { path in
            SessionNode(kind: .group(path), children: children(of: path))
        }
        let sessionNodes = sortedSessions(sessions.filter { $0.group == parent }).map {
            SessionNode(kind: .session($0), children: nil)
        }
        return groupNodes + sessionNodes
    }

    private func sortedSessions(_ list: [SessionProfile]) -> [SessionProfile] {
        list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// 侧边栏树的一个节点
public struct SessionNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case group(String)
        case session(SessionProfile)
    }

    public var kind: Kind
    /// 会话是叶子（nil）；分组总有数组（可能为空）
    public var children: [SessionNode]?

    public var id: String {
        switch kind {
        case .group(let path): "g:\(path)"
        case .session(let profile): "s:\(profile.id.uuidString)"
        }
    }

    public var title: String {
        switch kind {
        case .group(let path): GroupPath.lastComponent(of: path)
        case .session(let profile): profile.displayName
        }
    }

    public static func sessionID(from nodeID: String) -> UUID? {
        guard nodeID.hasPrefix("s:") else { return nil }
        return UUID(uuidString: String(nodeID.dropFirst(2)))
    }

    public static func groupPath(from nodeID: String) -> String? {
        guard nodeID.hasPrefix("g:") else { return nil }
        return String(nodeID.dropFirst(2))
    }
}
