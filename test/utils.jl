using Test
import JuliaFormatter
import JuMPConverter

function content(f)
    return open(io -> read(io, String), f)
end

function test_files(a, b)
    process = run(Cmd(`diff --color=always $a $b`, ignorestatus = true))
    @test process.exitcode == 0
end

name(f) = split(f, ".")[1]

function test_io(reader, input_dir, output_dir; ext::String = "")
    tmp = joinpath(@__DIR__, "tmp.jl")
    for f in readdir(input_dir)
        # Skip subdirectories and any file whose extension doesn't
        # match `ext` (e.g. companion `.dat` files alongside `.mod`s).
        isfile(joinpath(input_dir, f)) || continue
        isempty(ext) || endswith(f, ext) || continue
        @testset "$(name(f))" begin
            base_name = name(f)
            model = reader(joinpath(input_dir, f))
            open(tmp, "w") do io
                return println(io, model)
            end
            JuliaFormatter.format(tmp)
            JuliaFormatter.format(tmp)
            test_files(tmp, joinpath(output_dir, base_name * ".jl"))
        end
    end
end

function test_io(reader, root_dir; ext::String = "")
    input_dir = joinpath(root_dir, "input")
    output_dir = joinpath(root_dir, "output")
    return test_io(reader, input_dir, output_dir; ext)
end

"""
    test_output(reader, root_dir)

Regenerate output into a temp directory and diff against committed output.
Recursively walks `root_dir/input` for input files.
Output is not formatted — it is the raw JuMPConverter output.
"""
function test_output(reader, root_dir)
    input_dir = joinpath(root_dir, "input")
    output_dir = joinpath(root_dir, "output")
    mktempdir() do tmpdir
        return _generate_and_test(reader, input_dir, output_dir, tmpdir)
    end
end

function _generate_and_test(reader, input_dir, output_dir, tmpdir)
    for entry in sort(readdir(input_dir))
        input_path = joinpath(input_dir, entry)
        if isdir(input_path)
            _generate_and_test(
                reader,
                input_path,
                joinpath(output_dir, entry),
                joinpath(tmpdir, entry),
            )
        elseif endswith(entry, ".gms")
            mkpath(tmpdir)
            base_name = name(entry)
            tmp_path = joinpath(tmpdir, base_name * ".jl")
            expected_path = joinpath(output_dir, base_name * ".jl")
            model = reader(input_path)
            open(tmp_path, "w") do io
                return println(io, model)
            end
            @testset "$base_name" begin
                test_files(tmp_path, expected_path)
            end
        end
    end
end
