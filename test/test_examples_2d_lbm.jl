module TestExamples2DLatticeBoltzmann

using Test
using Trixi

include("test_trixi.jl")

# pathof(Trixi) returns /path/to/Trixi/src/Trixi.jl, dirname gives the parent directory
EXAMPLES_DIR = joinpath(pathof(Trixi) |> dirname |> dirname, "examples", "2d")

@testset "Lattice-Boltzmann" begin
  @trixi_testset "elixir_lbm_constant.jl" begin
    @test_trixi_include(joinpath(EXAMPLES_DIR, "elixir_lbm_constant.jl"),
      l2   = [4.888991832247047e-15, 4.8856380534982224e-15, 5.140829677785587e-16,
              7.340293204570167e-16, 2.0559494114924474e-15, 6.125746684189216e-16,
              1.6545443003155128e-16, 6.001333022242579e-16, 9.450994018139234e-15],
      linf = [5.551115123125783e-15, 5.662137425588298e-15, 1.2212453270876722e-15,
              1.27675647831893e-15, 2.4980018054066022e-15, 7.494005416219807e-16,
              4.3021142204224816e-16, 8.881784197001252e-16, 1.0436096431476471e-14])
  end

  @trixi_testset "elixir_lbm_couette.jl" begin
    @test_trixi_include(joinpath(EXAMPLES_DIR, "elixir_lbm_couette.jl"),
      l2   = [0.0007899749117603378, 7.0995283148275575e-6, 0.0007454191223764233,
              1.6482025869100257e-5, 0.00012684365365448903, 0.0001198942846383015,
              0.00028436349827736705, 0.0003005161103138576, 4.496683876631818e-5],
      linf = [0.005596384769998769, 4.771160474496827e-5, 0.005270322068908595,
              0.00011747787108790098, 0.00084326349695725, 0.000795551892211168,
              0.001956482118303543, 0.0020739599893902436, 0.00032606270109525326],
      tspan = (0.0, 1.0))
  end

  @trixi_testset "elixir_lbm_lid_driven_cavity.jl" begin
    @test_trixi_include(joinpath(EXAMPLES_DIR, "elixir_lbm_lid_driven_cavity.jl"),
      l2   = [0.0013628495945172754, 0.00021475256243322154, 0.0012579141312268184,
              0.00036542734715110765, 0.00024127756258120715, 0.00022899415795341014,
              0.0004225564518328741, 0.0004593854895507851, 0.00044244398903669927],
      linf = [0.025886626070758242, 0.00573859077176217, 0.027568805277855102, 0.00946724671122974,
              0.004031686575556803, 0.0038728927083346437, 0.020038695575169005,
              0.02061789496737146, 0.05568236920459335],
      tspan = (0.0, 1.0))
  end
end

end # module
