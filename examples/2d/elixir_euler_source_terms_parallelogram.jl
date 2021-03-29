
using OrdinaryDiffEq
using Trixi

###############################################################################
# semidiscretization of the compressible Euler equations

equations = CompressibleEulerEquations2D(1.4)

initial_condition = initial_condition_convergence_test

surface_flux = flux_lax_friedrichs
solver = DGSEM(3, surface_flux)

# Define faces for a parallelogram that looks like this
#
#             (0,1) __________ (2, 1)
#                ⟋         ⟋
#             ⟋         ⟋
#          ⟋         ⟋
# (-2,-1) ‾‾‾‾‾‾‾‾‾‾ (0,-1)
f1(s) = [s-1,  s]
f2(s) = [s+1,  s]
f3(s) = [s-1, -1]
f4(s) = [s+1,  1]

cells_per_dimension = (16, 16)

mesh = StructuredMesh(cells_per_dimension, [f1, f2, f3, f4], Float64)


semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver,
                                    source_terms=source_terms_convergence_test)


###############################################################################
# ODE solvers, callbacks etc.

tspan = (0.0, 2.0)
ode = semidiscretize(semi, tspan)

summary_callback = SummaryCallback()

analysis_interval = 100
analysis_callback = AnalysisCallback(semi, interval=analysis_interval)

alive_callback = AliveCallback(analysis_interval=analysis_interval)

save_solution = SaveSolutionCallback(interval=100,
                                     save_initial_solution=true,
                                     save_final_solution=true,
                                     solution_variables=cons2prim)

stepsize_callback = StepsizeCallback(cfl=0.5)

callbacks = CallbackSet(summary_callback,
                        analysis_callback, alive_callback,
                        save_solution,
                        stepsize_callback)

###############################################################################
# run the simulation

sol = solve(ode, CarpenterKennedy2N54(williamson_condition=false),
            dt=1.0, # solve needs some value here but it will be overwritten by the stepsize_callback
            save_everystep=false, callback=callbacks);
summary_callback() # print the timer summary
