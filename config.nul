use std.mem.Arena

let kind_null = 0
let kind_truth = 1
let kind_number = 2
let kind_text = 3
let kind_list = 4
let kind_object = 5

let depth_max = 32
let default_body_bytes = 1048576
let default_timeout_ms = 30000

pub struct Value {
    arena: Arena
    kind: i64
    number: i64
    text: str
    truth: bool
    members: ?*var Member
    count: i64

    pub fn isNull(self: Value) bool {
        return self.kind == kind_null
    }

    pub fn isList(self: Value) bool {
        return self.kind == kind_list
    }

    pub fn isObject(self: Value) bool {
        return self.kind == kind_object
    }

    pub fn isLeaf(self: Value) bool {
        return !self.isList() and !self.isObject()
    }

    pub fn length(self: Value) i64 {
        return self.count
    }

    pub fn describe(self: Value) str {
        if self.kind == kind_null {
            return "null"
        }
        if self.kind == kind_truth {
            return "a boolean"
        }
        if self.kind == kind_number {
            return "a number"
        }
        if self.kind == kind_text {
            return "text"
        }
        if self.kind == kind_list {
            return "a list"
        }
        return "an object"
    }

    pub fn put(self: *var Value, key: str, value: *var Value) {
        self.attach(self.arena.copy(key), value)
    }

    pub fn push(self: *var Value, value: *var Value) {
        self.attach("", value)
    }

    fn attach(self: *var Value, key: str, value: *var Value) {
        var member = self.arena.create[Member]()
        member.key = key
        member.value = value
        member.next = null

        var tail = self.members orelse {
            self.members = member
            self.count = self.count + 1
            return
        }
        while tail.next |following| {
            tail = following
        }
        tail.next = member
        self.count = self.count + 1
    }

    pub fn find(self: Value, key: str) ?*var Value {
        var next = self.members
        while next |member| {
            if member.key == key {
                return member.value
            }
            next = member.next
        }
        return null
    }

    pub fn at(self: Value, index: i64) ?*var Value {
        var next = self.members
        var remaining = index
        while next |member| {
            if remaining == 0 {
                return member.value
            }
            remaining = remaining - 1
            next = member.next
        }
        return null
    }

    pub fn reach(self: Value, outer: str, inner: str) ?*var Value {
        if self.find(outer) |found| {
            return found.find(inner)
        }
        return null
    }

    pub fn asNumber(self: Value) !i64 {
        if self.kind == kind_number {
            return self.number
        }
        return error.WrongKind
    }

    pub fn asText(self: Value) !str {
        if self.kind == kind_text {
            return self.text
        }
        return error.WrongKind
    }

    pub fn asTruth(self: Value) !bool {
        if self.kind == kind_truth {
            return self.truth
        }
        return error.WrongKind
    }

    pub fn requireNumber(self: Value, key: str) !i64 {
        let found = self.find(key) orelse { return error.Missing }
        return found.asNumber()
    }

    pub fn requireText(self: Value, key: str) !str {
        let found = self.find(key) orelse { return error.Missing }
        return found.asText()
    }

    pub fn numberOr(self: Value, key: str, fallback: i64) i64 {
        let found = self.find(key) orelse { return fallback }
        return found.asNumber() catch fallback
    }

    pub fn textOr(self: Value, key: str, fallback: str) str {
        let found = self.find(key) orelse { return fallback }
        return found.asText() catch fallback
    }

    pub fn leaves(self: Value, depth: i64) i64 {
        if depth > depth_max {
            return 0
        }
        if self.isLeaf() {
            return 1
        }

        var total = 0
        var next = self.members
        while next |member| {
            total = total + member.value.leaves(depth + 1)
            next = member.next
        }
        return total
    }
}

pub struct Member {
    key: str
    value: *var Value
    next: ?*var Member
}

pub struct Doc {
    arena: Arena

    pub fn open(arena: Arena) Doc {
        return .{ arena: arena }
    }

    pub fn nothing(self: Doc) *var Value {
        return self.blank(kind_null)
    }

    pub fn truth(self: Doc, of: bool) *var Value {
        var value = self.blank(kind_truth)
        value.truth = of
        return value
    }

    pub fn number(self: Doc, of: i64) *var Value {
        var value = self.blank(kind_number)
        value.number = of
        return value
    }

    pub fn text(self: Doc, of: str) *var Value {
        var value = self.blank(kind_text)
        value.text = self.arena.copy(of)
        return value
    }

    pub fn list(self: Doc) *var Value {
        return self.blank(kind_list)
    }

    pub fn object(self: Doc) *var Value {
        return self.blank(kind_object)
    }

    fn blank(self: Doc, kind: i64) *var Value {
        var value = self.arena.create[Value]()
        value.arena = self.arena
        value.kind = kind
        value.number = 0
        value.text = ""
        value.truth = false
        value.members = null
        value.count = 0
        return value
    }
}

pub struct Problem {
    path: str
    detail: str
}

pub struct Note {
    problem: Problem
    next: ?*var Note
}

pub struct Problems {
    arena: Arena
    first: ?*var Note
    last: ?*var Note
    count: i64

    pub fn open(arena: Arena) *var Problems {
        var problems = arena.create[Problems]()
        problems.arena = arena
        problems.first = null
        problems.last = null
        problems.count = 0
        return problems
    }

    pub fn record(self: *var Problems, path: str, detail: str) {
        var note = self.arena.create[Note]()
        note.problem = .{ path: self.arena.copy(path), detail: self.arena.copy(detail) }
        note.next = null

        if self.last |tail| {
            tail.next = note
        } else {
            self.first = note
        }
        self.last = note
        self.count = self.count + 1
    }

    pub fn holds(self: Problems, path: str) bool {
        var next = self.first
        while next |note| {
            if note.problem.path == path {
                return true
            }
            next = note.next
        }
        return false
    }

    pub fn isEmpty(self: Problems) bool {
        return self.count == 0
    }

    pub fn length(self: Problems) i64 {
        return self.count
    }
}

pub fn validate(arena: Arena, root: *var Value) *var Problems {
    var problems = Problems.open(arena)

    if !root.isObject() {
        problems.record("", "the document must be an object")
        return problems
    }

    var scratch = arena.child()
    defer scratch.destroy()

    checkListen(root, problems)
    checkLimits(root, problems)
    checkRoutes(root, Problems.open(scratch), problems)

    return problems
}

fn checkListen(root: *var Value, problems: *var Problems) {
    let listen = root.find("listen") orelse {
        problems.record("listen", "is required")
        return
    }

    _ = listen.requireText("host") catch {
        problems.record("listen.host", "must be text")
    }

    let port = listen.requireNumber("port") catch {
        problems.record("listen.port", "must be a number")
        return
    }
    if port < 1 or port > 65535 {
        problems.record("listen.port", "must be between 1 and 65535")
    }
}

fn checkLimits(root: *var Value, problems: *var Problems) {
    let limits = root.find("limits") orelse { return }

    if limits.numberOr("body_bytes_max", default_body_bytes) < 1 {
        problems.record("limits.body_bytes_max", "must be positive")
    }
    if limits.numberOr("timeout_ms", default_timeout_ms) < 1 {
        problems.record("limits.timeout_ms", "must be positive")
    }
}

fn checkRoutes(root: *var Value, seen: *var Problems, problems: *var Problems) {
    let routes = root.find("routes") orelse {
        problems.record("routes", "is required")
        return
    }

    if !routes.isList() {
        problems.record("routes", "must be a list")
        return
    }
    if routes.length() == 0 {
        problems.record("routes", "must not be empty")
        return
    }

    var next = routes.members
    while next |member| {
        checkRoute(member.value, seen, problems)
        next = member.next
    }
}

fn checkRoute(route: *var Value, seen: *var Problems, problems: *var Problems) {
    if !route.isObject() {
        problems.record("routes", "every route must be an object")
        return
    }

    let path = route.requireText("path") catch {
        problems.record("routes", "every route needs a path")
        return
    }

    if seen.holds(path) {
        problems.record(path, "is declared twice")
    } else {
        seen.record(path, "")
    }

    _ = route.requireText("handler") catch {
        problems.record(path, "needs a handler")
    }
}

pub struct Settings {
    host: str
    port: i64
    body_bytes_max: i64
    timeout_ms: i64
    routes: i64
}

pub fn settingsOf(root: *var Value) !Settings {
    let listen = root.find("listen") orelse { return error.Missing }
    let routes = root.find("routes") orelse { return error.Missing }

    return .{
        host: try listen.requireText("host"),
        port: try listen.requireNumber("port"),
        body_bytes_max: limitOf(root, "body_bytes_max", default_body_bytes),
        timeout_ms: limitOf(root, "timeout_ms", default_timeout_ms),
        routes: routes.length(),
    }
}

fn limitOf(root: *var Value, key: str, fallback: i64) i64 {
    let limits = root.find("limits") orelse { return fallback }
    return limits.numberOr(key, fallback)
}

fn route(doc: Doc, path: str, handler: str) *var Value {
    var value = doc.object()
    value.put("path", doc.text(path))
    value.put("handler", doc.text(handler))
    return value
}

fn sample(doc: Doc) *var Value {
    var root = doc.object()

    var listen = doc.object()
    listen.put("host", doc.text("0.0.0.0"))
    listen.put("port", doc.number(8080))
    root.put("listen", listen)

    var limits = doc.object()
    limits.put("body_bytes_max", doc.number(262144))
    limits.put("timeout_ms", doc.number(5000))
    root.put("limits", limits)

    var routes = doc.list()
    routes.push(route(doc, "/", "index"))
    routes.push(route(doc, "/health", "health"))
    routes.push(route(doc, "/metrics", "metrics"))
    root.put("routes", routes)

    root.put("verbose", doc.truth(true))
    root.put("tls", doc.nothing())

    return root
}

pub fn main() !i64 {
    var arena = Arena.init()

    let doc = Doc.open(arena)
    let root = sample(doc)

    let problems = validate(arena, root)
    if !problems.isEmpty() {
        return error.InvalidConfiguration
    }

    let settings = try settingsOf(root)
    if settings.port != 8080 {
        return error.InvalidConfiguration
    }

    if root.reach("listen", "nowhere") |found| {
        _ = found
        return error.InvalidConfiguration
    }

    return settings.routes + root.leaves(0)
}
