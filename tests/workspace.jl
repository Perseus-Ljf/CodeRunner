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

@testset "IPC protocol" begin
    server = listen(ip"127.0.0.1", 0)
    peer = nothing
    try
        @test CodeRunnerWorkspace.start(getsockname(server)[2], "test-token") === nothing
        peer = accept(server)
        @test readline(peer) == "HELLO\ttest-token\t1"
        println(peer, "REFRESH\t7\t500\t120")
        flush(peer)
        @test readline(peer) == "BEGIN\t7"
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
