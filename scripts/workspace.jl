module CodeRunnerWorkspace

using Sockets
using REPL

const PROTOCOL_VERSION = 2
const CONNECTION = Ref{Union{Nothing,TCPSocket}}(nothing)
const WRITE_LOCK = ReentrantLock()
const CHANGE_PENDING = Ref{Union{Nothing,TCPSocket}}(nothing)
const CHANGE_VERSION = Ref(0)
const MAX_DEPTH = 8
const MAX_NODES = 10000
const SCALAR_TYPES = (Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16,
    UInt32, UInt64, UInt128, Float16, Float32, Float64, Char, Symbol, Nothing, Missing)

struct UndefinedField end
const UNDEFINED = UndefinedField()
const Item = Tuple{String,String,String,String,Int,Bool}

struct Node
    value::Any
    ancestors::Vector{Any}
end

mutable struct Store
    generation::Int
    next_id::Int
    nodes::Dict{Int,Node}
    children::Dict{Int,Tuple{Vector{Item},Bool}}
end
Store() = Store(0, 0, Dict{Int,Node}(), Dict{Int,Tuple{Vector{Item},Bool}}())

clip(text::String, limit::Int) = length(text) > limit ? first(text, limit) * "..." : text

# Raw fields and built-in containers only: never call custom show/getproperty.
# Keep inspection type-erased: a REPL can introduce new concrete types at any time.
function expandable(@nospecialize(value))
    (value isa UndefinedField || value isa AbstractString || value isa Symbol ||
        value isa Type || value isa Function || value isa Module || value isa Dict ||
        value isa Task || value isa IO || typeof(value) in SCALAR_TYPES) && return false
    (value isa Array || value isa BitArray) && return !isempty(value)
    return isstructtype(typeof(value)) && fieldcount(typeof(value)) > 0
end

function preview(@nospecialize(value), limit::Int)
    if value isa UndefinedField
        return "#undef"
    elseif value isa String || value isa SubString{String}
        return clip(repr(first(value, limit)), limit)
    elseif typeof(value) in SCALAR_TYPES
        return clip(repr(value), limit)
    elseif value isa Array || value isa BitArray
        parts = String[]
        for i in 1:min(length(value), 6)
            push!(parts, isassigned(value, i) ? scalar_preview(value[i], limit) : "#undef")
        end
        length(value) > 6 && push!(parts, "...")
        return clip("[" * join(parts, ", ") * "]", limit)
    elseif value isa Dict
        return string(length(value), " entries")
    elseif value isa Function
        return "<function>"
    elseif value isa Module
        return "<module>"
    elseif value isa Type
        return "<type>"
    elseif expandable(value)
        count = fieldcount(typeof(value))
        return string(count, count == 1 ? " field" : " fields")
    else
        return "<preview omitted>"
    end
end

function scalar_preview(@nospecialize(value), limit)
    if value isa String || value isa SubString{String} || typeof(value) in SCALAR_TYPES
        return preview(value, limit)
    end
    return "<" * clip(string(typeof(value)), limit) * ">"
end

function describe(@nospecialize(name), @nospecialize(value), limit::Int)
    dimensions = value isa Array || value isa BitArray ? join(size(value), " x ") : ""
    type = value isa UndefinedField ? "" : clip(string(typeof(value)), 512)
    return (clip(string(name), 512), type, clip(dimensions, 128), preview(value, limit))
end

function item(store::Store, @nospecialize(name), @nospecialize(value), limit::Int, ancestors=Any[])
    description = Base.invokelatest(describe, name, value, limit)
    can_expand = expandable(value)
    if can_expand && any(parent -> parent === value, ancestors)
        return (description[1:3]..., "<circular reference>", 0, false)
    elseif can_expand && length(ancestors) >= MAX_DEPTH
        return (description[1:3]..., "<maximum depth>", 0, false)
    elseif can_expand && length(store.nodes) >= MAX_NODES
        return (description[1:3]..., "<node limit>", 0, false)
    elseif can_expand
        store.next_id += 1
        store.nodes[store.next_id] = Node(value, [ancestors; Any[value]])
        return (description..., store.next_id, true)
    end
    return (description..., 0, false)
end

function snapshot(max_items::Int, preview_length::Int, store::Store=Store())
    store.generation += 1
    store.next_id = 0
    empty!(store.nodes)
    empty!(store.children)
    rows = Item[]
    truncated = false
    for name in sort!(names(Main; all=true, imported=false); by=string)
        text = string(name)
        (startswith(text, "#") || name in (:Main, :Base, :Core, :eval, :include, :CodeRunnerWorkspace)) && continue
        isdefined(Main, name) || continue
        Base.isdeprecated(Main, name) && continue
        value = getfield(Main, name)
        value isa Module && continue
        if length(rows) >= max_items
            truncated = true
            break
        end
        row = try
            item(store, name, value, preview_length)
        catch
            (clip(text, 512), "<unavailable>", "", "<inspection failed>", 0, false)
        end
        push!(rows, row)
    end
    return rows, truncated
end

function children(store::Store, generation::Int, id::Int, limit::Int, preview_length::Int)
    generation == store.generation || error("Workspace changed; refresh before expanding")
    haskey(store.nodes, id) || error("Object is no longer available")
    haskey(store.children, id) && return store.children[id]
    node = store.nodes[id]
    value = node.value
    array = value isa Array || value isa BitArray
    count = array ? length(value) : fieldcount(typeof(value))
    rows = Item[]
    for index in 1:min(count, limit)
        name = array ? "[$index]" : string(fieldname(typeof(value), index))
        child = if array
            isassigned(value, index) ? value[index] : UNDEFINED
        else
            isdefined(value, index) ? getfield(value, index) : UNDEFINED
        end
        push!(rows, item(store, name, child, preview_length, node.ancestors))
    end
    result = (rows, count > limit)
    store.children[id] = result
    return result
end

# Send notifications separately, so a closed or slow editor cannot change the
# result or exception of the user's evaluation. Serialize writes with replies.
function changed()
    socket = CONNECTION[]
    socket === nothing && return nothing
    CHANGE_VERSION[] += 1
    CHANGE_PENDING[] === socket && return nothing
    CHANGE_PENDING[] = socket
    @async try
        while CONNECTION[] === socket && isopen(socket)
            version = CHANGE_VERSION[]
            lock(WRITE_LOCK) do
                if CONNECTION[] === socket && isopen(socket)
                    write(socket, "CHANGED\n")
                    flush(socket)
                end
            end
            # An evaluation can finish while the write yields. Do not lose
            # that final update just because a notification was in flight.
            version == CHANGE_VERSION[] && break
        end
    catch
    finally
        CHANGE_PENDING[] === socket && (CHANGE_PENDING[] = nothing)
    end
    return nothing
end

function evaluate(mod::Module, ast)
    try
        # Julia 1.12's entry point preserves package-install hooks and top-level
        # lowering. Older REPLs evaluate the already-softscoped AST directly.
        if isdefined(REPL, :toplevel_eval_with_hooks)
            return Base.invokelatest(REPL.toplevel_eval_with_hooks, mod, ast)
        end
        return Core.eval(mod, ast)
    finally
        changed()
    end
end

function transform(ast)
    CONNECTION[] === nothing && return ast
    mod = isdefined(Base, :active_module) ? Base.active_module() : Main
    return Expr(:call, GlobalRef(CodeRunnerWorkspace, :evaluate), QuoteNode(mod), QuoteNode(ast))
end

function install_hook()
    isdefined(Base, :active_repl_backend) || return false
    backend = Base.active_repl_backend
    hasproperty(backend, :ast_transforms) || return false
    transforms = backend.ast_transforms
    any(hook -> hook === transform, transforms) || push!(transforms, transform)
    return true
end

function reply(socket, id, store, rows, truncated)
    # println on a TCP stream writes its arguments separately. Buffer the full
    # frame to avoid small-packet/delayed-ACK stalls and hundreds of syscalls.
    buffer = IOBuffer()
    println(buffer, "BEGIN\t", id, '\t', store.generation)
    for row in rows
        text = join(bytes2hex.(codeunits.(row[1:4])), '\t')
        println(buffer, "VAR\t", id, '\t', text, '\t', row[5], '\t', row[6] ? "1" : "0")
    end
    println(buffer, "END\t", id, '\t', truncated ? "1" : "0")
    payload = take!(buffer)
    lock(WRITE_LOCK) do
        write(socket, payload)
        flush(socket)
    end
end

# v2: LF/tab records, hex UTF-8 text, generation-scoped opaque object ids.
# Requests never carry expressions, property paths, or serialized Julia values.
function serve(socket::TCPSocket, token::String, hooked::Bool)
    store = Store()
    try
        write(socket, "HELLO\t$token\t2\t$(hooked ? 1 : 0)\n")
        flush(socket)
        while isopen(socket) && !eof(socket)
            request = readline(socket)
            ncodeunits(request) <= 256 || break
            fields = split(request, '\t')
            length(fields) in (4, 6) || break
            numbers = tryparse.(Int, fields[2:end])
            all(number -> number !== nothing && number > 0, numbers) || break
            id = numbers[1]
            limit, preview_length = numbers[end-1:end]
            (1 <= limit <= 2000 && 16 <= preview_length <= 512) || break
            try
                rows, truncated = if fields[1] == "REFRESH" && length(fields) == 4
                    # In Julia 1.12, newly created global bindings also have a
                    # world age. The long-lived socket task must see the latest.
                    Base.invokelatest(snapshot, limit, preview_length, store)
                elseif fields[1] == "CHILDREN" && length(fields) == 6 && limit <= 500
                    Base.invokelatest(children, store, numbers[2], numbers[3], limit, preview_length)
                else
                    break
                end
                reply(socket, id, store, rows, truncated)
            catch
                lock(WRITE_LOCK) do
                    message = bytes2hex(codeunits("Object changed or inspection failed; refresh to retry"))
                    write(socket, "ERROR\t$id\t$message\n")
                    flush(socket)
                end
            end
        end
    catch err
        @debug "Workspace connection stopped" exception=(err, catch_backtrace())
    finally
        isopen(socket) && close(socket)
        CONNECTION[] === socket && (CONNECTION[] = nothing)
    end
end

function start(port::Integer, token::String)
    previous = CONNECTION[]
    previous !== nothing && isopen(previous) && close(previous)
    socket = connect(ip"127.0.0.1", port)
    Sockets.nagle(socket, false)
    CONNECTION[] = socket
    hooked = install_hook()
    errormonitor(@async serve(socket, token, hooked))
    return nothing
end

# Compile the type-erased traversal once while loading the helper, rather than
# on the first keypress. This does not enumerate or retain any user objects.
precompile(children, (Store, Int, Int, Int, Int))
precompile(setindex!, (Dict{Int,Tuple{Vector{Item},Bool}}, Tuple{Vector{Item},Bool}, Int))

end
