// Sources/ToolSystem/Agent/TodoTool.swift
// Read and update a task/todo list

import Foundation

/// Manages a persistent todo list for task tracking.
public struct TodoTool: Tool {
    public let name = "todo"
    public let description = "Read or update a todo list. Items are never hidden — completed items stay in the list marked [x], pending items are marked [ ]. Actions: 'read' to view all items, 'add' to append a new [ ] item, 'complete' to change [ ] to [x], 'uncomplete' to change [x] back to [ ] (use this to reopen/mark-as-pending — do NOT remove+add), 'remove' to permanently delete. CRITICAL: When working on tasks, only process ONE AT A TIME. Stop and ask the user for permission before moving to the next task."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": PropertySchema(type: "string", description: "Action to perform. Use 'uncomplete' to revert a completed item — do NOT simulate it with remove+add.", enumValues: ["read", "add", "complete", "uncomplete", "remove"]),
            "item": PropertySchema(type: "integer", description: "1-based todo number for 'complete'/'uncomplete'/'remove' (e.g. 1 for the first item, 2 for the second)"),
            "item_text": PropertySchema(type: "string", description: "Todo item text for 'add'"),
        ],
        required: ["action"]
    )

    private let todoFilePath: String
    private let legacyTodoFilePath: String

    public init(workspaceRoot: String) {
        self.todoFilePath = (workspaceRoot as NSString).appendingPathComponent(".mlx-coder-todo")
        self.legacyTodoFilePath = (workspaceRoot as NSString).appendingPathComponent(".native-agent-todo.md")
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return .error("Missing required argument: action")
        }

        switch action {
        case "read":
            return readTodos()
        case "add":
            guard let item = arguments["item_text"] as? String else {
                return .error("Missing required argument: item_text (for 'add')")
            }
            return addTodo(item)
        case "complete":
            guard let index = integerTodoIndex(from: arguments["item"]) else {
                return .error("Missing or invalid argument: item (provide the todo number as a numeric value)")
            }
            return completeTodo(at: index)
        case "uncomplete":
            guard let index = integerTodoIndex(from: arguments["item"]) else {
                return .error("Missing or invalid argument: item (provide the todo number as a numeric value)")
            }
            return uncompleteTodo(at: index)
        case "remove":
            guard let index = integerTodoIndex(from: arguments["item"]) else {
                return .error("Missing or invalid argument: item (provide the todo number as a numeric value)")
            }
            return removeTodo(at: index)
        default:
            return .error("Unknown action: \(action). Use 'read', 'add', 'complete', 'uncomplete', or 'remove'.")
        }
    }

    // MARK: - Private

    private func loadTodos() -> [String] {
        let content =
            (try? String(contentsOfFile: todoFilePath, encoding: .utf8))
            ?? (try? String(contentsOfFile: legacyTodoFilePath, encoding: .utf8))
        guard let content else {
            return []
        }
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map(normalizeTodoFormat)
    }

    private func saveTodos(_ todos: [String]) {
        let content = todos.map(normalizeTodoFormat).joined(separator: "\n")
        do {
            try content.write(toFile: todoFilePath, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: legacyTodoFilePath) {
                try? FileManager.default.removeItem(atPath: legacyTodoFilePath)
            }
        } catch {
            // Preserve existing best-effort behavior: ignore write failures.
        }
    }

    private func readTodos() -> ToolResult {
        let todos = loadTodos()
        if todos.isEmpty {
            return .success("(no todos)")
        }
        let numbered = todos.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return .success(numbered.joined(separator: "\n"))
    }

    private func addTodo(_ item: String) -> ToolResult {
        var todos = loadTodos()
        todos.append("[ ] \(item)")
        saveTodos(todos)
        return .success("Added: \(item)")
    }

    private func completeTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        todos[i] = markTodoCompleted(todos[i])
        saveTodos(todos)
        return .success("Completed: \(todos[i])")
    }

    private func uncompleteTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        todos[i] = markTodoUncompleted(todos[i])
        saveTodos(todos)
        return .success("Uncompleted: \(todos[i])")
    }

    private func removeTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        let removed = todos.remove(at: i)
        saveTodos(todos)
        return .success("Removed: \(removed)")
    }

    private func integerTodoIndex(from rawValue: Any?) -> Int? {
        switch rawValue {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    private func normalizeTodoFormat(_ todo: String) -> String {
        if todo.hasPrefix("[ ]") {
            return normalizeCheckboxSpacing(todo, prefix: "[ ]")
        }

        if todo.hasPrefix("[x]") {
            return normalizeCheckboxSpacing(todo, prefix: "[x]")
        }

        guard todo.hasPrefix("[]") else {
            return todo
        }

        return normalizeLegacyUncheckedCheckbox(todo)
    }

    private func markTodoCompleted(_ todo: String) -> String {
        let normalizedTodo = normalizeTodoFormat(todo)
        if normalizedTodo.hasPrefix("[ ]") {
            return completeUncheckedTodo(normalizedTodo)
        }
        return normalizedTodo
    }

    private func markTodoUncompleted(_ todo: String) -> String {
        let normalizedTodo = normalizeTodoFormat(todo)
        if normalizedTodo.hasPrefix("[x]") {
            return uncompleteCheckedTodo(normalizedTodo)
        }
        return normalizedTodo
    }

    private func normalizeLegacyUncheckedCheckbox(_ todo: String) -> String {
        let remainder = String(todo.dropFirst(2))
        return normalizeCheckboxSpacing("[ ]" + remainder, prefix: "[ ]")
    }

    private func completeUncheckedTodo(_ todo: String) -> String {
        let remainder = String(todo.dropFirst(3))
        return normalizeCheckboxSpacing("[x]" + remainder, prefix: "[x]")
    }

    private func uncompleteCheckedTodo(_ todo: String) -> String {
        let remainder = String(todo.dropFirst(3))
        return normalizeCheckboxSpacing("[ ]" + remainder, prefix: "[ ]")
    }

    private func normalizeCheckboxSpacing(_ todo: String, prefix: String) -> String {
        let remainder = String(todo.dropFirst(prefix.count))
        if remainder.isEmpty {
            return prefix
        }
        if remainder.hasPrefix(" ") {
            return prefix + remainder
        }
        return prefix + " " + remainder
    }
}
