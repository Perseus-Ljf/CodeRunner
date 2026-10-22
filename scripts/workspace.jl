module CodeRunnerWorkspace

using Sockets

const CONNECTION = Ref{Union{Nothing,TCPSocket}}(nothing)
const SCALAR_TYPES = (Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16,
    UInt32, UInt64, UInt128, Float16, Float32, Float64, Char, Symbol, Nothing, Missing)

clip(text::String, limit::Int) = length(text) > limit ? first(text, limit) * "..." : text

# Only inspect built-in containers and scalars: arbitrary show/getproperty methods
# can run user code, allocate unbounded output, or block the REPL.
function preview(value, limit::Int)
    if value isa String || value isa SubString{String}
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
    else
        return "<preview omitted>"
    end
end

function scalar_preview(value, limit)
    if value isa String || value isa SubString{String} || typeof(value) in SCALAR_TYPES
        return preview(value, limit)
    end
    return "<" * clip(string(typeof(value)), limit) * ">"
end

function describe(name::Symbol, value, limit::Int)
    dimensions = if value isa Array || value isa BitArray
        join(size(value), " x ")
    else
        ""
    end
    return (clip(string(name), 512), clip(string(typeof(value)), 512),
        clip(dimensions, 128), preview(value, limit))
end

function snapshot(max_items::Int, preview_length::Int)
    rows = NTuple{4,String}[]
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
            Base.invokelatest(describe, name, value, preview_length)
        catch
            (clip(text, 512), "<unavailable>", "", "<inspection failed>")
        end
        push!(rows, row)
    end
    return rows, truncated
end

# Protocol v1: LF-delimited, tab-separated records. All text fields are UTF-8
# encoded as hex using bytes2hex; no Julia serialization or eval crosses IPC.
function serve(socket::TCPSocket, token::String)
    try
        println(socket, "HELLO\t", token, "\t1")
        flush(socket)
        while isopen(socket) && !eof(socket)
            request = readline(socket)
            ncodeunits(request) <= 256 || break
            fields = split(request, '\t')
            length(fields) == 4 && fields[1] == "REFRESH" || break
            id = tryparse(Int, fields[2])
            max_items = tryparse(Int, fields[3])
            preview_length = tryparse(Int, fields[4])
            (id !== nothing && max_items !== nothing && preview_length !== nothing) || break
            (id > 0 && 1 <= max_items <= 2000 && 16 <= preview_length <= 512) || break
            try
                rows, truncated = Base.invokelatest(snapshot, max_items, preview_length)
                println(socket, "BEGIN\t", id)
                for row in rows
                    println(socket, "VAR\t", id, '\t', join(bytes2hex.(codeunits.(row)), '\t'))
                end
                println(socket, "END\t", id, '\t', truncated ? "1" : "0")
            catch
                println(socket, "ERROR\t", id, '\t', bytes2hex(codeunits("Unable to inspect Main")))
            end
            flush(socket)
        end
    catch err
        # The editor may close the connection on timeout or exit.
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
    CONNECTION[] = socket
    errormonitor(@async serve(socket, token))
    return nothing
end

end
