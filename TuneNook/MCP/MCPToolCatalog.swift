import MCP

/// The 12 TuneNook tools as MCP tool definitions. Schemas mirror the validation in `TuneNook/MCP/Tools/`.
enum MCPToolCatalog {
    static let tools: [MCP.Tool] = [
        tool("list_topics",
             "Lists every topic with its id, name, color, deadline and open and done task counts.",
             readOnly: true),
        tool("create_topic",
             "Creates a topic and returns it.",
             ["name": string("Topic name. Must not be empty."),
              "color": string("Topic color.", enum: Topic.palette),
              "deadline": string("Optional deadline, ISO 8601 or YYYY-MM-DD.")],
             required: ["name"]),
        tool("update_topic",
             "Changes a topic's name, color or deadline and returns the updated topic.",
             ["id": string("Topic id from list_topics."),
              "name": string("New topic name. Must not be empty."),
              "color": string("New topic color.", enum: Topic.palette),
              "deadline": nullableString("New deadline, ISO 8601 or YYYY-MM-DD, or null to remove the deadline.")],
             required: ["id"]),
        tool("delete_topic",
             "Deletes a topic and all of its tasks, and returns {\"deleted\": true}; fails while a focus session is running on one of its tasks.",
             ["id": string("Topic id from list_topics.")],
             required: ["id"], destructive: true),
        tool("list_tasks",
             "Lists tasks with their id, title, topic, estimated and actual sessions and done state; open tasks come first.",
             ["status": string("Which tasks to return. Defaults to open.", enum: ["open", "done", "all"]),
              "topic_id": string("Only return tasks in this topic.")],
             readOnly: true),
        tool("create_task",
             "Creates a task in a topic and returns it.",
             ["title": string("Task title. Must not be empty."),
              "topic_id": string("Id of the topic the task belongs to, from list_topics."),
              "estimated_sessions": integer("Estimated focus sessions. Defaults to 1.", min: 1, max: 12)],
             required: ["title", "topic_id"]),
        tool("update_task",
             "Changes a task's title, topic, estimate or done state and returns the updated task.",
             ["id": string("Task id from list_tasks."),
              "title": string("New task title. Must not be empty."),
              "topic_id": string("Id of the topic to move the task to."),
              "estimated_sessions": integer("New estimated focus sessions.", min: 1, max: 12),
              "done": boolean("True marks the task done, false reopens it.")],
             required: ["id"]),
        tool("delete_task",
             "Deletes a task and returns {\"deleted\": true}; fails while a focus session is running on it.",
             ["id": string("Task id from list_tasks.")],
             required: ["id"], destructive: true),
        tool("get_settings",
             "Returns the timer, daily goal, break music, celebration and away settings, plus the allowed values for each.",
             readOnly: true),
        tool("update_settings",
             "Changes the given timer, goal, break music, celebration or away settings and returns the full settings; nothing is changed if any value is invalid.",
             ["focus_minutes": integer("Focus session length in minutes.", min: 5, max: 90),
              "short_break_minutes": integer("Short break length in minutes.", min: 1, max: 30),
              "long_break_minutes": integer("Long break length in minutes.", min: 5, max: 60),
              "long_break_interval": integer("Focus sessions before a long break.", min: 2, max: 8),
              "auto_start_breaks": boolean("Start breaks automatically."),
              "auto_start_focus": boolean("Start the next focus session automatically."),
              "daily_goal": .object([
                  "type": "object",
                  "description": "Daily goal. For minutes the target is a multiple of 15 from 15 to 600; for sessions it is 1 to 16.",
                  "properties": .object([
                      "kind": string("Goal unit.", enum: ["minutes", "sessions"]),
                      "target": integer("Goal target, in the chosen unit.", min: 1, max: 600),
                  ]),
                  "required": ["kind", "target"],
              ]),
              "break_music": string("What music does during breaks.",
                                    enum: ["keepPlaying", "lowerVolume", "stop", "switchStation"]),
              "break_station_id": nullableString("Station id from get_settings allowed.stations, or null for none."),
              "celebrations": string("How often to celebrate.", enum: ["off", "milestones", "everySession"]),
              "pause_on_lock": boolean("Pause the timer when the Mac locks."),
              "idle_pause_minutes": .object([
                  "type": "integer",
                  "description": "Minutes of inactivity before pausing; 0 turns it off.",
                  "enum": [0, 2, 5, 10, 15],
              ])]),
        tool("list_sessions",
             "Lists focus and break sessions, newest first, with times, active minutes, task and topic; defaults to the last 7 days.",
             ["from": string("Start of range, ISO 8601 or YYYY-MM-DD. Defaults to 7 days before to."),
              "to": string("End of range, ISO 8601 or YYYY-MM-DD (inclusive). Defaults to now."),
              "topic_id": string("Only sessions on tasks in this topic."),
              "task_id": string("Only sessions on this task."),
              "kind": string("Only this kind of session.", enum: ["focus", "shortBreak", "longBreak"]),
              "completed_only": boolean("Only sessions that ran to completion."),
              "limit": integer("Maximum sessions to return. Defaults to 100.", min: 1, max: 500)],
             readOnly: true),
        tool("get_progress",
             "Returns today's minutes and sessions against the daily goal, the streak, and per-day totals.",
             ["days": integer("How many days to include, ending today. Defaults to 7.", min: 1, max: 366)],
             readOnly: true),
    ]

    // MARK: Builders

    private static func tool(_ name: String, _ description: String, _ properties: [String: Value] = [:],
                             required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> MCP.Tool {
        MCP.Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
            annotations: .init(readOnlyHint: readOnly ? true : nil,
                               destructiveHint: destructive ? true : nil,
                               openWorldHint: false))
    }

    private static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    private static func nullableString(_ description: String) -> Value {
        .object(["type": .array(["string", "null"]), "description": .string(description)])
    }

    private static func integer(_ description: String, min: Int, max: Int) -> Value {
        .object(["type": "integer", "description": .string(description), "minimum": .int(min), "maximum": .int(max)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }
}
