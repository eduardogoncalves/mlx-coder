// Sources/ToolSystem/Agent/TodoTool.swift
// Read and update a task/todo list

import Foundation

/// Manages a persistent todo list for task tracking.
public struct TodoTool: Tool {
    public let name = "todo"
    public let description = "Read or update a todo list. Use action 'read' to view, 'add' to add an item, 'complete' to mark as done, 'remove' to delete. CRITICAL: When working on tasks, only process ONE AT A TIME. Stop and ask the user for permission before moving to the next task."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": PropertySchema(type: "string", description: "Action to perform", enumValues: ["read", "add", "complete", "remove"]),
            "item": PropertySchema(type: "integer", description: "Todo index for 'complete'/'remove' (numeric value)"),
            "item_text": PropertySchema(type: "string", description: "Todo item text for 'add'"),
        ],
        required: ["action"]
    )

    private let todoFilePath: String

    public init(workspaceRoot: String) {
        self.todoFilePath = (workspaceRoot as NSString).appendingPathComponent(".native-agent-todo.md")
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return .error("Missing required argument: action")
        }

        switch action {
        case "read":
            return readTodos()
        case "add":
            let itemText = arguments["item_text"] as? String ?? arguments["item"] as? String
            guard let item = itemText else {
                return .error("Missing required argument: item_text (for 'add')")
            }
            return addTodo(item)
        case "complete":
            guard let index = integerTodoIndex(from: arguments["item"]) else {
                return .error("Missing or invalid argument: item (provide the todo number as a numeric value)")
            }
            return completeTodo(at: index)
        case "remove":
            guard let index = integerTodoIndex(from: arguments["item"]) else {
                return .error("Missing or invalid argument: item (provide the todo number as a numeric value)")
            }
            return removeTodo(at: index)
        default:
            return .error("Unknown action: \(action). Use 'read', 'add', 'complete', or 'remove'.")
        }
    }

    // MARK: - Private

    private func loadTodos() -> [String] {
        guard let content = try? String(contentsOfFile: todoFilePath, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func saveTodos(_ todos: [String]) {
        let content = todos.joined(separator: "\n")
        try? content.write(toFile: todoFilePath, atomically: true, encoding: .utf8)
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
            return .error("Invalid todo number: \(index) (have \(todos.count) items)")
        }
        todos[i] = todos[i].replacingOccurrences(of: "[ ]", with: "[x]")
        saveTodos(todos)
        return .success("Completed: \(todos[i])")
    }

    private func removeTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (have \(todos.count) items)")
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
}
