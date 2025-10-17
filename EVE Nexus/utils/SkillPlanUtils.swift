import Foundation

/// 技能计划辅助类 - 处理技能添加的共享逻辑
class SkillPlanHelper {
    
    // 添加技能及其所有前置依赖
    static func collectSkillsToAdd(
        skillId: Int,
        skillName: String,
        targetLevel: Int,
        databaseManager: DatabaseManager,
        currentSkillLevels: [Int: Int],
        addedSkills: inout Set<Int>,
        skillLevels: inout [Int: Int]
    ) -> [(skillId: Int, skillName: String, level: Int)] {
        Logger.debug("[+] 开始添加技能到计划 - 技能: \(skillName) (ID: \(skillId)), 等级: \(targetLevel)")
        
        let currentTargetLevel = currentSkillLevels[skillId] ?? 0
        
        // 收集要添加的所有技能（用于批量添加）
        var skillsToAdd: [(skillId: Int, skillName: String, level: Int)] = []
        
        // 只在技能从0级添加时检查前置依赖
        if !addedSkills.contains(skillId) {
            Logger.debug("[+] 技能未添加，检查前置技能依赖")
            
            // 获取所有前置技能
            let prerequisites = getAllPrerequisites(
                skillId: skillId,
                requiredLevel: targetLevel,
                databaseManager: databaseManager
            )
            
            // 收集前置技能
            for prereq in prerequisites {
                let currentLevel = currentSkillLevels[prereq.skillId] ?? 0
                let requiredLevel = prereq.requiredLevel
                
                if !addedSkills.contains(prereq.skillId) {
                    let prereqSkillName = getSkillName(skillId: prereq.skillId, databaseManager: databaseManager)
                    skillsToAdd.append((skillId: prereq.skillId, skillName: prereqSkillName, level: requiredLevel))
                    addedSkills.insert(prereq.skillId)
                    skillLevels[prereq.skillId] = requiredLevel
                } else if currentLevel < requiredLevel {
                    let prereqSkillName = getSkillName(skillId: prereq.skillId, databaseManager: databaseManager)
                    skillsToAdd.append((skillId: prereq.skillId, skillName: prereqSkillName, level: requiredLevel))
                    skillLevels[prereq.skillId] = requiredLevel
                }
            }
            
            // 收集目标技能所有等级
            for currentLevel in 1 ... targetLevel {
                skillsToAdd.append((skillId: skillId, skillName: skillName, level: currentLevel))
            }
            addedSkills.insert(skillId)
            skillLevels[skillId] = targetLevel
        } else if currentTargetLevel < targetLevel {
            // 升级技能
            for currentLevel in (currentTargetLevel + 1) ... targetLevel {
                skillsToAdd.append((skillId: skillId, skillName: skillName, level: currentLevel))
            }
            skillLevels[skillId] = targetLevel
        }
        
        return skillsToAdd
    }
    
    // 获取前置技能（按依赖深度排序）
    private static func getAllPrerequisites(
        skillId: Int,
        requiredLevel: Int,
        databaseManager: DatabaseManager
    ) -> [(skillId: Int, requiredLevel: Int)] {
        let requirements = SkillTreeManager.shared.getDeduplicatedSkillRequirements(
            for: skillId, databaseManager: databaseManager
        )
        
        // 计算每个技能的依赖深度
        var skillDepths: [Int: Int] = [:]
        for requirement in requirements {
            let depth = calculateSkillDepth(skillId: requirement.skillID, databaseManager: databaseManager)
            skillDepths[requirement.skillID] = depth
        }
        
        var allPrerequisites: [(skillId: Int, requiredLevel: Int)] = []
        for requirement in requirements {
            for level in 1 ... requirement.level {
                allPrerequisites.append((skillId: requirement.skillID, requiredLevel: level))
            }
        }
        
        // 按深度排序（深度小的先=最底层的前置优先）
        return allPrerequisites.sorted { first, second in
            let depth1 = skillDepths[first.skillId] ?? 0
            let depth2 = skillDepths[second.skillId] ?? 0
            
            if depth1 != depth2 {
                return depth1 < depth2  // 深度小的优先（最底层优先）
            } else if first.skillId == second.skillId {
                return first.requiredLevel < second.requiredLevel  // 同一技能，等级从低到高
            } else {
                return first.skillId < second.skillId  // 同深度，按 ID 排序
            }
        }
    }
    
    // 计算技能的依赖深度（递归）
    private static func calculateSkillDepth(skillId: Int, databaseManager: DatabaseManager) -> Int {
        let directReqs = SkillTreeManager.shared.getDeduplicatedSkillRequirements(
            for: skillId, databaseManager: databaseManager
        )
        
        if directReqs.isEmpty {
            return 0  // 没有前置，深度为0
        }
        
        // 深度 = 1 + 所有前置技能的最大深度
        let maxPrereqDepth = directReqs.map { req in
            calculateSkillDepth(skillId: req.skillID, databaseManager: databaseManager)
        }.max() ?? 0
        
        return 1 + maxPrereqDepth
    }
    
    // 获取技能名称
    private static func getSkillName(skillId: Int, databaseManager: DatabaseManager) -> String {
        let query = "SELECT name FROM types WHERE type_id = ?"
        if case let .success(rows) = databaseManager.executeQuery(query, parameters: [skillId]),
           let row = rows.first,
           let name = row["name"] as? String
        {
            return name
        }
        return "Unknown Skill (\(skillId))"
    }
}

