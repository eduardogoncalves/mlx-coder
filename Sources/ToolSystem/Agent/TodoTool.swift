// Sources/ToolSystem/Agent/TodoTool.swift
// Read and update a task/todo list

import Foundation

/// Manages a persistent todo list for task tracking.
public struct TodoTool: Tool {
    public let name = "todo"
    public let description = "Read or update a todo list. Items are never hidden — completed items stay in the list marked [x], pending items are marked [ ]. Actions: 'read' to view all items, 'add' to append a new [ ] item, 'complete' to change [ ] to [x], 'uncomplete' to reopen a completed item, 'remove' to permanently delete. CRITICAL: When working on tasks, only process ONE AT A TIME. Stop and ask the user for permission before moving to the next task."
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
    /// Non-nil only for ephemeral (sub-agent) instances — when set, all reads
    /// and writes go through this in-memory store instead of the filesystem,
    /// so `todoFilePath`/`legacyTodoFilePath` are unused placeholders.
    private let ephemeralStore: EphemeralTodoStore?

    /// Prefix shared by all session-namespaced todo files, used both to build
    /// a namespaced path and to recognize stale ones left behind by earlier
    /// runs so they can be swept up on startup.
    private static let namespacedFilePrefix = ".mlx-coder-todo-"

    /// - Parameters:
    ///   - workspaceRoot: Root directory the todo file(s) live under.
    ///   - sessionNamespace: When non-nil/non-empty, scopes persistence to a
    ///     `.mlx-coder-todo-<namespace>` file instead of the shared
    ///     `.mlx-coder-todo` file, so a fresh top-level run (fresh namespace)
    ///     never inherits items left over by a previous, unrelated run.
    ///     Constructing with a namespace also sweeps any other
    ///     `.mlx-coder-todo-*` files out of the workspace, so stale
    ///     namespaced files from earlier runs don't accumulate. Leave `nil`
    ///     to reproduce the original, un-namespaced single-file behavior
    ///     exactly (back-compat default for existing callers).
    ///   - ephemeral: When true, ignores `workspaceRoot`/`sessionNamespace`
    ///     entirely and backs this instance with a private in-memory store —
    ///     used for sub-agent todos, which must start empty, never touch the
    ///     orchestrator's persisted file, and leave nothing behind once the
    ///     sub-agent (and this instance) goes out of scope.
    public init(workspaceRoot: String, sessionNamespace: String? = nil, ephemeral: Bool = false) {
        if ephemeral {
            self.ephemeralStore = EphemeralTodoStore()
            self.todoFilePath = ""
            self.legacyTodoFilePath = ""
            return
        }

        self.ephemeralStore = nil
        self.legacyTodoFilePath = (workspaceRoot as NSString).appendingPathComponent(".native-agent-todo.md")
        if let sessionNamespace, !sessionNamespace.isEmpty {
            let fileName = "\(TodoTool.namespacedFilePrefix)\(sessionNamespace)"
            self.todoFilePath = (workspaceRoot as NSString).appendingPathComponent(fileName)
            TodoTool.cleanupStaleNamespacedFiles(workspaceRoot: workspaceRoot, keepingFileName: fileName)
        } else {
            self.todoFilePath = (workspaceRoot as NSString).appendingPathComponent(".mlx-coder-todo")
        }
    }

    /// Removes any `.mlx-coder-todo-<other-namespace>` files left behind by
    /// earlier runs, keeping only the file for the namespace currently being
    /// constructed. Best-effort: failures are silently ignored (a leftover
    /// file is a minor annoyance, not a correctness issue).
    private static func cleanupStaleNamespacedFiles(workspaceRoot: String, keepingFileName: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: workspaceRoot) else { return }
        for entry in entries {
            guard entry.hasPrefix(namespacedFilePrefix), entry != keepingFileName else { continue }
            try? fm.removeItem(atPath: (workspaceRoot as NSString).appendingPathComponent(entry))
        }
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return .error("Missing required argument: action")
        }

        switch action {
        case "read":
            return readTodos()
        case "add":
            // Canonical arg is `item_text`, but small models commonly reach for
            // `text` or put the todo string straight into `item` (the field they
            // otherwise use for the numeric index). Accept those aliases so a
            // well-formed add isn't rejected over a field-name mismatch.
            guard let item = addItemText(from: arguments) else {
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
        if let ephemeralStore {
            return ephemeralStore.load()
        }

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

    private func saveTodos(_ todos: [String]) -> Bool {
        let normalized = todos.map(normalizeTodoFormat)

        if let ephemeralStore {
            ephemeralStore.save(normalized)
            return true
        }

        let content = normalized.joined(separator: "\n")
        do {
            try content.write(toFile: todoFilePath, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: legacyTodoFilePath) {
                try? FileManager.default.removeItem(atPath: legacyTodoFilePath)
            }
            return true
        } catch {
            return false
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
        let persisted = saveTodos(todos)
        return .success(successMessage("Added: \(item)", persisted: persisted))
    }

    private func completeTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        todos[i] = markTodoCompleted(todos[i])
        let persisted = saveTodos(todos)
        return .success(successMessage("Completed: \(todos[i])", persisted: persisted))
    }

    private func uncompleteTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        todos[i] = markTodoUncompleted(todos[i])
        let persisted = saveTodos(todos)
        return .success(successMessage("Uncompleted: \(todos[i])", persisted: persisted))
    }

    private func removeTodo(at index: Int) -> ToolResult {
        var todos = loadTodos()
        let i = index - 1
        guard i >= 0, i < todos.count else {
            return .error("Invalid todo number: \(index) (valid range is 1–\(todos.count))")
        }
        let removed = todos.remove(at: i)
        let persisted = saveTodos(todos)
        return .success(successMessage("Removed: \(removed)", persisted: persisted))
    }

    private func successMessage(_ message: String, persisted: Bool) -> String {
        guard !persisted else { return message }
        return "\(message) (warning: failed to persist todo file changes)"
    }

    /// Resolves the todo text for an `add`, tolerating the common field-name
    /// aliases small models emit. `item` is accepted only when it carries a
    /// non-numeric string (its numeric form is the index for other actions).
    private func addItemText(from arguments: [String: Any]) -> String? {
        for key in ["item_text", "text"] {
            if let value = arguments[key] as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        if let value = arguments["item"] as? String,
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value
        }
        return nil
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
        let todo = stripOrderedListPrefix(todo)
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

    private func stripOrderedListPrefix(_ todo: String) -> String {
        let trimmedLeading = todo.drop(while: { $0.isWhitespace })
        guard !trimmedLeading.isEmpty else { return todo }
        var idx = trimmedLeading.startIndex
        while idx < trimmedLeading.endIndex, trimmedLeading[idx].isNumber {
            idx = trimmedLeading.index(after: idx)
        }
        guard idx > trimmedLeading.startIndex,
              idx < trimmedLeading.endIndex,
              trimmedLeading[idx] == "." || trimmedLeading[idx] == ")" else {
            return todo
        }
        idx = trimmedLeading.index(after: idx)
        while idx < trimmedLeading.endIndex, trimmedLeading[idx].isWhitespace {
            idx = trimmedLeading.index(after: idx)
        }
        guard idx < trimmedLeading.endIndex else { return todo }
        return String(trimmedLeading[idx...])
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

/// Thread-safe in-memory backing store for ephemeral `TodoTool` instances
/// (sub-agent todos). Deliberately never touches disk: state lives only for
/// as long as this instance is referenced (i.e. for the lifetime of the
/// sub-agent's tool registry), and is simply released — no cleanup step is
/// needed because nothing was ever persisted.
private final class EphemeralTodoStore: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [String] = []

    func load() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return todos
    }

    func save(_ newTodos: [String]) {
        lock.lock()
        defer { lock.unlock() }
        todos = newTodos
    }
}
