module NewPkgEval

using BinaryBuilder
using BinaryProvider
import Pkg.TOML
using Pkg
import Base: UUID
using Dates

downloads_dir(name) = joinpath(@__DIR__, "..", "deps", "downloads", name)
julia_path(ver) = joinpath(@__DIR__, "..", "deps", "julia-$ver")
versions_file() = joinpath(@__DIR__, "..", "deps", "Versions.toml")
registry_path() = joinpath(first(DEPOT_PATH), "registries", "General")

include("build_julia.jl")

"""
    get_registry()

Download the default registry, or if it already exists, update it.
"""
function get_registry()
    Pkg.Types.clone_default_registries()
    Pkg.Types.update_registries(Pkg.Types.Context())
end

"""
    read_versions() -> Dict

Parse the `deps/Versions.toml` file containing version and download information for
various versions of Julia.
"""
function read_versions()
    vers = TOML.parse(read(versions_file(), String))
end

"""
    obtain_julia(the_ver)

Download the specified version of Julia using the information provided in `Versions.toml`.
"""
function obtain_julia(the_ver::VersionNumber)
    vers = read_versions()
    for (ver, data) in vers
        ver = VersionNumber(ver)
        ver == the_ver || continue
        if haskey(data, "url")
            file = get(data, "file", "julia-$ver.tar.gz")
            @assert !isabspath(file)
            download_verify_unpack(
                data["url"],
                data["sha"],
                julia_path(ver);
                tarball_path=downloads_dir(file),
                force=true
            )
        else
            file = data["file"]
            !isabspath(file) && (file = downloads_dir(file))
            BinaryProvider.verify(file, data["sha"])
            isdir(julia_path(ver)) || BinaryProvider.unpack(file, julia_path(ver))
        end
        return
    end
    error("Requested Julia version not found")
end

function installed_julia_dir(ver)
     jp = julia_path(ver)
     jp_contents = readdir(jp)
     # Allow the unpacked directory to either be insider another directory (as produced by
     # the buildbots) or directly inside the mapped directory (as produced by the BB script)
     if length(jp_contents) == 1
         jp = joinpath(jp, first(jp_contents))
     end
     jp
end

"""
    run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The keyword
argument `ver` specifies the version of Julia to use, and `do_obtain` dictates whether
the specified version should first be downloaded. If `do_obtain` is `false`, it must
already be installed.
"""
function run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true, kwargs...)
    if do_obtain
        obtain_julia(ver)
    else
        @assert ispath(julia_path(ver))
    end
    ispath(registry_path()) || error("Please run `NewPkgEval.get_registry()` first")
    runner = BinaryBuilder.UserNSRunner(pwd(),
        workspaces=[
            installed_julia_dir(ver) => "/maps/julia",
            registry_path() => "/maps/registries/General"
        ])
    BinaryBuilder.run_interactive(runner, `/maps/julia/bin/julia --color=yes $args`; kwargs...)
end

log_path(ver) = joinpath(@__DIR__, "..", "logs/logs-$ver")

"""
    run_sandboxed_test(pkg; ver::VersionNumber, do_depwarns=false, time_limit=60*45, kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox using the Julia version
`ver`. If `do_depwarns` is `true`, deprecation warnings emitted while running the package's
tests will cause the tests to fail. Test will be forcibly interrupted after `time_limit` seconds.

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.
"""
function run_sandboxed_test(pkg; ver::VersionNumber, do_depwarns=false, time_limit=60*45, kwargs...)
    @assert ispath(julia_path(ver))
    mkpath(log_path(ver))
    log = joinpath(log_path(ver), "$pkg.log")
    arg = """
        using Pkg
        # TODO: Possible to remove?
        open("/etc/hosts", "w") do f
            println(f, "127.0.0.1\tlocalhost")
        end
        # Map the local registry to the sandbox registry
        mkpath("/root/.julia/registries")
        run(`ln -s /maps/registries/General /root/.julia/registries/General`)
        # Prevent Pkg from updating registy on the Pkg.add
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
        Pkg.add($(repr(pkg)))
        Pkg.test($(repr(pkg)))
    """
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd -e $arg`
    timed_out = false
    open(log, "w") do f
        try
            t = @async run_sandboxed_julia(cmd; ver=ver, kwargs..., stdout=f, stderr=f)
            Timer(time_limit) do timer
                timed_out = true
                try; schedule(t, InterruptException(); error=true); catch; end
            end
            wait(t)
            return !timed_out
        catch e
            return false
        end
    end
end

# Skip these packages when testing packages
const skip_list = [
    "AbstractAlgebra", # Hangs forever
    "DiscretePredictors", # Hangs forever
    "LinearLeastSquares", # Hangs forever
    "SLEEF", # Hangs forever
    "OrthogonalPolynomials", # Hangs forever
    "IndexableBitVectors",
    "LatinHypercubeSampling", # Hangs forever
    "DynamicalBilliards", # Hangs forever
    "ChangePrecision", # Hangs forever
    "Rectangle", # Hangs forever
    "Parts", # Hangs forever
    "ZippedArrays", # Hangs forever
    "Chunks", # Hangs forever
    "Electron",
    "DotOverloading",
    "ValuedTuples",
    "HCubature",
    "SequentialMonteCarlo",
    "RequirementVersions",
    "NumberedLines",
    "LazyContext",
    "RecurUnroll", # deleted, hangs
    "TypedBools", # deleted, hangs
    "LazyCall", # deleted, hangs
    "MeshCatMechanisms",
    "SessionHacker",
    "Embeddings",
    "GeoStatsDevTools",
    "DataDeps", # hangs
    "DataDepsGenerators", # hangs
    "MackeyGlass", # deleted, hangs
    "Keys", #deleted, hangs
]

# Blindly assume these packages are okay
const ok_list = [
    "BinDeps", # Not really ok, but packages may list it just as a fallback
    "Homebrew",
    "WinRPM",
    "NamedTuples", # As requested by quinnj
    "Compat",
]

# Stdlibs are assumed to be ok
append!(ok_list, readdir(Sys.STDLIB))

"""
    run(depsgraph, ninstances, version[, result]; do_depwarns=false, 
        time_limit=60*45)

Run all tests for all packages in the given package dependency graph using `ninstances`
workers and the specified version of Julia. An existing result `Dict` can be specified,
in which case the function will write to that.

If the keyword argument `do_depwarns` is `true`, deprecation warnings emitted in package
tests will cause the package's tests to fail, i.e. Julia is run with `--depwarn=error`.

Tests will be forcibly interrupted after `time_limit` seconds.
"""
function run(pkgs, ninstances::Integer, ver::VersionNumber, result = Dict{String, Symbol}();
             do_depwarns=false, time_limit=60*45, skip_dependees_for_failed_pkgs = false)
    obtain_julia(ver)
    # In case we need to provide sudo password, do that before starting the actual testing
    run_sandboxed_julia(`-e '1'`; ver=ver)
    get_registry() # make sure local registry is updated

    pkgs = copy(pkgs)
    npkgs = length(pkgs)
    running = Vector{Union{Nothing, Symbol}}(nothing, ninstances)
    times = DateTime[now() for i = 1:ninstances]
    all_workers = Task[]

    done = false
    did_signal_workers = false
    function stop_work()
        if !done
            done = true
            if !did_signal_workers
                for (i, task) in enumerate(all_workers)
                    task == current_task() && continue
                    Base.istaskdone(task) && continue
                    try; schedule(task, InterruptException(); error=true); catch; end
                    running[i] = nothing
                end
                did_signal_workers = true
            end
        end
    end

    @sync begin
        # Printer
        @async begin
            try
                io = IOContext(IOBuffer(), :color=>true)
                while (!isempty(pkgs) || !all(==(nothing), running)) && !done
                    o = count(==(:ok),      values(result))
                    f = count(==(:fail),    values(result))
                    s = count(==(:skipped), values(result))
                    print(io, "Success: ")
                    printstyled(io, o; color = :green)
                    print(io, "\tFailed: ")
                    printstyled(io, f; color = Base.error_color())
                    print(io, "\tSkipped: ")
                    printstyled(io, s; color = Base.warn_color())
                    println(io, "\tRemaining: ", npkgs - (o + f + s))
                    for i = 1:ninstances
                        r = running[i]
                        if r === nothing
                            println(io, "Worker $i: -------")
                        else
                            time = Dates.canonicalize(Dates.CompoundPeriod(now() - times[i]))
                            pop!(time.periods) # get rid of milliseconds
                            println(io, "Worker $i: $(r) running for ", time)
                        end
                    end
                    print(String(take!(io.io)))
                    sleep(1)
                    CSI = "\e["
                    print(io, "$(CSI)$(ninstances+1)A$(CSI)1G$(CSI)0J")
                end
                stop_work()
            catch e
                Base.@show e
                stop_work()
                !isa(e, InterruptException) && rethrow(e)
            end
        end
        # Workers
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(pkgs) && !done
                        pkg = pop!(pkgs)
                        running[i] = Symbol(pkg.name)
                        times[i] = now()
                        result[pkg.name] = run_sandboxed_test(pkg.name, do_depwarns=do_depwarns, ver=ver,
                                                         time_limit = time_limit, do_obtain=false) ? :ok : :fail
                        running[i] = nothing
                    end
                catch e
                    @Base.show e
                    stop_work()
                    isa(e, InterruptException) || rethrow(e)
                end
            end)
        end
    end
    return result
end

"""
    read_pkgs([pkgs::Vector{String}])

Read packages from the default registry and return them as a vector of tuples containing
the package name, its UUID, and a path to it. If `pkgs` is given, only collect packages
matching the names in `pkgs`
"""
function read_pkgs(pkgs::Union{Nothing, Vector{String}}=nothing)
    pkg_data = []
    for registry in (registry_path(),)
        open(joinpath(registry, "Registry.toml")) do io
            for (_uuid, pkgdata) in Pkg.Types.read_registry(joinpath(registry, "Registry.toml"))["packages"]
                uuid = UUID(_uuid)
                name = pkgdata["name"]
                if pkgs !== nothing
                    idx = findfirst(==(name), pkgs)
                    idx === nothing && continue
                    deleteat!(pkgs, idx)
                end
                path = abspath(registry, pkgdata["path"])
                push!(pkg_data, (name=name, uuid=uuid, path=path))
            end
        end
    end
    if pkgs !== nothing && !isempty(pkgs)
        @warn """did not find the following packages in the registry:\n $("  - " .* join(pkgs, '\n'))"""
    end
    pkg_data
end

end # module
