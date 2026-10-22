using Test
using Sockets
include(joinpath(@__DIR__, "..", "scripts", "workspace.jl"))

struct UnsafeDisplay end
Base.show(::IO, ::UnsafeDisplay) = error("Workspace must not call this")
struct UnsafeArray <: AbstractVector{Int} end
Base.size(::UnsafeArray) = error("Workspace must not call this")
Base.getindex(::UnsafeArray, ::Int) = error("Workspace must not call this")

@testset "Conservative previews" begin
    @test CodeRunnerWorkspace.preview(42, 120) == "42"
    @test CodeRunnerWorkspace.preview(nothing, 120) == "nothing"
    @test CodeRunnerWorkspace.preview(missing, 120) == "missing"
    @test CodeRunnerWorkspace.preview("line\n\tvalue", 120) == repr("line\n\tvalue")
    @test length(CodeRunnerWorkspace.preview(repeat("x", 1_000_000), 32)) <= 35
    @test length(CodeRunnerWorkspace.preview(repeat("\u4f60\u597d", 1000), 32)) <= 35
    @test CodeRunnerWorkspace.preview(collect(1:100), 120) == "[1, 2, 3, 4, 5, 6, ...]"
    @test CodeRunnerWorkspace.preview(Vector{String}(undef, 2), 120) == "[#undef, #undef]"
    @test CodeRunnerWorkspace.preview(UnsafeDisplay(), 120) == "<preview omitted>"
    @test CodeRunnerWorkspace.preview(UnsafeArray(), 120) == "<preview omitted>"
    @test CodeRunnerWorkspace.preview([UnsafeDisplay()], 120) == "[<UnsafeDisplay>]"
    @test CodeRunnerWorkspace.describe(:matrix, ones(2, 3), 120)[3] == "2 x 3"
    @test CodeRunnerWorkspace.preview(Dict(:a => 1), 120) == "1 entries"
end

workspace_test_value = 42
workspace_test_text = "\u4f60\u597d\n\tvalue"
workspace_test_unsafe = UnsafeDisplay()

@testset "Main snapshot" begin
    rows, truncated = CodeRunnerWorkspace.snapshot(500, 120)
    values = Dict(row[1] => row for row in rows)
    @test values["workspace_test_value"][4] == "42"
    @test values["workspace_test_text"][4] == repr(workspace_test_text)
    @test values["workspace_test_unsafe"][4] == "<preview omitted>"
    @test !haskey(values, "CodeRunnerWorkspace")
    @test !haskey(values, "Main")
    @test !truncated
    limited, truncated = CodeRunnerWorkspace.snapshot(1, 120)
    @test length(limited) == 1
    @test truncated
end

struct WorkspaceAddress
    city::String
    zip::Int
end
mutable struct WorkspacePerson
    name::String
    address::WorkspaceAddress
    values::Vector{Int}
end
Base.getproperty(::WorkspacePerson, ::Symbol) = error("No custom property access")
Base.show(::IO, ::WorkspacePerson) = error("No custom display")
mutable struct WorkspaceLink
    child::Any
    WorkspaceLink() = new()
    WorkspaceLink(child) = new(child)
end

@testset "Raw-field trees" begin
    person = WorkspacePerson("Ada", WorkspaceAddress("Paris", 75001), collect(1:10))
    store = CodeRunnerWorkspace.Store()
    store.generation = 1
    root = CodeRunnerWorkspace.item(store, "person", person, 120)
    @test root[4] == "3 fields"
    @test root[6]
    fields, truncated = CodeRunnerWorkspace.children(store, 1, root[5], 100, 120)
    @test !truncated
    @test first.(fields) == ["name", "address", "values"]
    @test fields[1][4] == repr("Ada")
    address, _ = CodeRunnerWorkspace.children(store, 1, fields[2][5], 100, 120)
    @test address[1][4] == repr("Paris")
    @test address[2][4] == "75001"
    array, truncated = CodeRunnerWorkspace.children(store, 1, fields[3][5], 2, 120)
    @test truncated
    @test first.(array) == ["[1]", "[2]"]
    @test array[2][4] == "2"
    @test CodeRunnerWorkspace.children(store, 1, root[5], 100, 120)[1] === fields

    tuple = CodeRunnerWorkspace.item(store, "pair", (left=3, right="four"), 120)
    pair, _ = CodeRunnerWorkspace.children(store, 1, tuple[5], 100, 120)
    @test first.(pair) == ["left", "right"]
    @test pair[1][4] == "3"
    unassigned = CodeRunnerWorkspace.item(store, "unassigned", Vector{String}(undef, 2), 120)
    slots, _ = CodeRunnerWorkspace.children(store, 1, unassigned[5], 100, 120)
    @test all(row -> row[4] == "#undef" && !row[6], slots)

    link = WorkspaceLink()
    undef_root = CodeRunnerWorkspace.item(store, "link", link, 120)
    fields, _ = CodeRunnerWorkspace.children(store, 1, undef_root[5], 100, 120)
    @test fields[1][4] == "#undef"
    link.child = link
    cyclic = CodeRunnerWorkspace.item(store, "cycle", link, 120)
    fields, _ = CodeRunnerWorkspace.children(store, 1, cyclic[5], 100, 120)
    @test fields[1][4] == "<circular reference>"
    @test !fields[1][6]

    nested = WorkspaceLink(nothing)
    for _ in 1:12
        nested = WorkspaceLink(nested)
    end
    deep = CodeRunnerWorkspace.item(store, "deep", nested, 120)
    while deep[6]
        deep = CodeRunnerWorkspace.children(store, 1, deep[5], 100, 120)[1][1]
    end
    @test deep[4] == "<maximum depth>"
    CodeRunnerWorkspace.snapshot(500, 120, store)
    @test_throws ErrorException CodeRunnerWorkspace.children(store, 1, root[5], 100, 120)
end

@testset "REPL evaluation semantics" begin
    probe = Module(:WorkspaceEvaluationProbe)
    @test CodeRunnerWorkspace.evaluate(probe, :(value = 41)) == 41
    @test CodeRunnerWorkspace.evaluate(probe, :(value + 1)) == 42
    ast = CodeRunnerWorkspace.REPL.softscope(:(begin
        total = 0
        for i in 1:4
            total += i
        end
        total
    end))
    @test CodeRunnerWorkspace.evaluate(probe, ast) == 10
    CodeRunnerWorkspace.evaluate(probe, :(struct WrappedType; x::Int; end))
    @test CodeRunnerWorkspace.evaluate(probe, :(WrappedType(7).x)) == 7
    CodeRunnerWorkspace.evaluate(probe, :(macro double(x); :($(esc(x)) * 2); end))
    @test CodeRunnerWorkspace.evaluate(probe, :(@double 3)) == 6
    @test_throws ErrorException CodeRunnerWorkspace.evaluate(probe, :(begin
        partial = 99
        error("intentional")
    end))
    @test getfield(probe, :partial) == 99
end

mutable struct WriteCounter <: IO
    buffer::IOBuffer
    writes::Int
end
Base.unsafe_write(io::WriteCounter, data::Ptr{UInt8}, count::UInt) = (io.writes += 1; Base.unsafe_write(io.buffer, data, count))
Base.write(io::WriteCounter, byte::UInt8) = (io.writes += 1; write(io.buffer, byte))
Base.flush(io::WriteCounter) = flush(io.buffer)

@testset "Batched response frames" begin
    store = CodeRunnerWorkspace.Store()
    store.generation = 7
    rows = CodeRunnerWorkspace.Item[("\u53d8\u91cf", "String", "", "line\n\tvalue", 3, true)]
    output = WriteCounter(IOBuffer(), 0)
    CodeRunnerWorkspace.reply(output, 11, store, rows, true)
    @test output.writes == 1
    lines = split(String(take!(output.buffer)), '\n'; keepempty=false)
    @test length(lines) == 3
    @test lines[1] == "BEGIN\t11\t7"
    @test lines[3] == "END\t11\t1"
    fields = split(lines[2], '\t')
    @test fields[1:2] == ["VAR", "11"]
    @test Tuple(String(hex2bytes(field)) for field in fields[3:6]) == rows[1][1:4]
    @test fields[7:8] == ["3", "1"]
end

@testset "IPC protocol" begin
    server = listen(ip"127.0.0.1", 0)
    peer = nothing
    try
        @test CodeRunnerWorkspace.start(getsockname(server)[2], "test-token") === nothing
        peer = accept(server)
        @test readline(peer) == "HELLO\ttest-token\t2\t0"
        println(peer, "REFRESH\t7\t500\t120")
        flush(peer)
        @test readline(peer) == "BEGIN\t7\t1"
        values = Dict{String,Vector{String}}()
        while true
            record = split(readline(peer), '\t')
            if record[1] == "END"
                @test record == ["END", "7", "0"]
                break
            end
            @test record[1:2] == ["VAR", "7"]
            decoded = [String(hex2bytes(field)) for field in record[3:6]]
            values[decoded[1]] = decoded
        end
        @test values["workspace_test_value"][4] == "42"
        @test values["workspace_test_text"][4] == repr(workspace_test_text)
        println(peer, "REFRESH\t8\t0\t120")
        flush(peer)
        @test eof(peer)
    finally
        peer !== nothing && close(peer)
        close(server)
    end
end
