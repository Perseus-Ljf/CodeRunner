# Opt-in microbenchmarks; no packages and no timing assertions in CI.
using Sockets
using Printf
using Statistics
include(joinpath(@__DIR__, "..", "scripts", "workspace.jl"))

struct BenchLeaf
    label::String
    count::Int
end
struct BenchModel
    leaf::BenchLeaf
    values::Vector{Float64}
end
bench_model = BenchModel(BenchLeaf("test", 42), collect(1.0:100.0))
bench_array = collect(1:500)

function report(label, values)
    @printf("%-38s first=%9.3f ms  median=%9.3f ms\n", label, first(values), median(values[2:end]))
end

function benchmark()
    store = CodeRunnerWorkspace.Store()
    rows, _ = CodeRunnerWorkspace.snapshot(500, 120, store)
    for name in ("bench_model", "bench_array")
        row = only(filter(row -> row[1] == name, rows))
        samples = Float64[]
        for _ in 1:11
            empty!(store.children)
            elapsed = @elapsed CodeRunnerWorkspace.children(store, store.generation, row[5], 500, 120)
            push!(samples, elapsed * 1000)
        end
        report("Julia enumeration: $name", samples)
    end

    server = listen(ip"127.0.0.1", 0)
    peer = nothing
    try
        CodeRunnerWorkspace.start(getsockname(server)[2], "benchmark")
        peer = accept(server)
        readline(peer)
        function request(text)
            started = time_ns()
            # Match Neovim's single write for a complete request.
            write(peer, text * "\n")
            flush(peer)
            data = String[]
            while true
                line = readline(peer)
                isempty(line) && eof(peer) && error("Workspace disconnected during benchmark")
                push!(data, line)
                startswith(line, "ERROR") && error(line)
                startswith(line, "END") && break
            end
            return (time_ns() - started) / 1e6, data
        end
        _, response = request("REFRESH\t1\t500\t120")
        references = Dict{String,Int}()
        for line in response
            fields = split(line, '\t')
            if fields[1] == "VAR"
                references[String(hex2bytes(fields[3]))] = parse(Int, fields[7])
            end
        end
        sequence = 1
        for name in ("bench_model", "bench_array")
            samples = Float64[]
            for _ in 1:11
                sequence += 1
                elapsed, _ = request("CHILDREN\t$sequence\t1\t$(references[name])\t500\t120")
                push!(samples, elapsed)
            end
            report("TCP expansion: $name", samples)
        end
    finally
        peer !== nothing && close(peer)
        close(server)
    end
end

benchmark()
