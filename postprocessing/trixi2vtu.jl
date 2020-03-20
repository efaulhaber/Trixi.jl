#!/bin/bash

# This file uses the method outlined in [1] to pass additional arguments to the
# `julia` executable (in this case: enable colored output). The approach should
# work portably on all UNIX-like operating systems.
#
# NOTE TO WINDOWS USERS: Just invoke `bin/trixi` explicitly with the `julia` executable.
#
# [1]: https://docs.julialang.org/en/v1/manual/faq/#How-do-I-pass-options-to-julia-using-#!/usr/bin/env?-1

#=
# Check if '-i' or '--interactive' was passed as an argument
interactive=0
for arg in "$@"; do
  if [ "$arg" = "-i" ] || [ "$arg" = "--interactive" ]; then
    interactive=1
  fi
done

# If not interactive, just run script as usual. Otherwise load REPL
if [ $interactive -eq 0 ]; then
  exec julia --color=yes \
      -e 'run_script=true; include(popfirst!(ARGS))' "${BASH_SOURCE[0]}" "$@" 
else
  exec julia --banner=no -i \
      -e 'println("# Execute the first line below once at the beginning of an interactive session.")' \
      -e 'println("# Start plotting by running the second line.\n")' \
      -e "println(\"using Revise; push!(Revise.dont_watch_pkgs, :Plots); includet(\\\"${BASH_SOURCE[0]}\\\")\")" \
      -e 'println("TrixiPlot.run(datafile=\"file.h5\")")'
fi
=#

module Trixi2Vtu

# Get useful bits and pieces from trixi
include("../src/solvers/interpolation.jl")

# Number of spatial dimensions
const ndim = 2

using .Interpolation: gauss_lobatto_nodes_weights,
                      polynomial_interpolation_matrix, interpolate_nodes
using .PointLocators: PointLocator, insert!, Point

using ArgParse: ArgParseSettings, @add_arg_table, parse_args
using HDF5: h5open, attrs
using WriteVTK: vtk_grid, MeshCell, VTKCellTypes
using TimerOutputs

function run(;args=nothing, kwargs...)
  # Reset timer
  reset_timer!()

  # Handle command line arguments
  if !isnothing(args)
    # If args are given explicitly, parse command line arguments
    args = parse_commandline_arguments(args)
  else
    # Otherwise interpret keyword arguments as command line arguments
    args = Dict{String, Any}()
    for (key, value) in kwargs
      args[string(key)] = value
    end

    # Clean up some of the arguments and provide defaults
    # FIXME: This is redundant to parse_commandline_arguments
    # If datafile is a single string, convert it to array
    if !haskey(args, "datafile")
      println(stderr, "error: no datafile was provided")
      return
    end
    if isa(args["datafile"], String)
      args["datafile"] = [args["datafile"]]
    end
    if !haskey(args, "format")
      args["format"] = "png"
    end
    if !haskey(args, "variable")
      args["variable"] = []
    end
    if !haskey(args, "grid_lines")
      args["grid_lines"] = false
    end
    if !haskey(args, "verbose")
      args["verbose"] = false
    end
    if !haskey(args, "output_directory")
      args["output_directory"] = "."
    end
    if !haskey(args, "nvisnodes")
      args["nvisnodes"] = nothing
    end
  end
  verbose = args["verbose"]

  # Iterate over input files
  for datafile in args["datafile"]
    verbose && println("Processing file $datafile...")

    # Check if data file exists
    if !isfile(datafile)
      error("data file '$datafile' does not exist")
    end

    # Get mesh file name
    meshfile = extract_mesh_filename(datafile)

    # Check if mesh file exists
    if !isfile(meshfile)
      error("mesh file '$meshfile' does not exist")
    end

    # Read mesh
    verbose && println("| Reading mesh file...")
    @timeit "read mesh" (center_level_0, length_level_0,
                         leaf_cells, coordinates, levels) = read_meshfile(meshfile)

    # Read data
    verbose && println("| Reading data file...")
    @timeit "read data" labels, unstructured_data, n_nodes, time = read_datafile(datafile)

    # Calculate VTK points and cells
    vtk_points, vtk_cells, = calc_vtk_points_cells(coordinates, levels,
                                                   center_level_0, length_level_0)

    # Create VTK file and store cell ids
    vtk_grid("datafile") do vtk_file
      vtk["cell_ids"] = leaf_cells
      vtk["element_ids"] = collect(1:length(leaf_cells))
    end
    return


    # Determine resolution for data interpolation
    if args["nvisnodes"] == nothing
      nvisnodes = 4 * n_nodes
    elseif args["nvisnodes"] == 0
      nvisnodes = n_nodes
    else
      nvisnodes = args["nvisnodes"]
    end

    # Interpolate unstructured DG data to structured data
    verbose && println("| Interpolating data...")
    #=@show minimum(unstructured_data), maximum(unstructured_data)=#
    @timeit "interpolate data" (structured_data =
        unstructured2structured(unstructured_data, normalized_coordinates,
                                levels, resolution, nvisnodes_per_level))

    # Interpolate cell-centered values to node-centered values
    #=@show minimum(structured_data), maximum(structured_data)=#
    node_centered_data = cell2node(structured_data)
    #=@show minimum(node_centered_data), maximum(node_centered_data)=#

    # Determine axis coordinates for contour plot
    xs = collect(range(-1, 1, length=resolution+1)) .* length_level_0/2 .+ center_level_0[1]
    ys = collect(range(-1, 1, length=resolution+1)) .* length_level_0/2 .+ center_level_0[2]

    # Determine element vertices to plot grid lines
    if args["grid_lines"]
      vertices_x, vertices_y = calc_vertices(coordinates, levels, length_level_0)
    end

    # Set up plotting
    output_format = get_output_format(args["format"])
    gr()
    if output_format == :pdf
      GR.inline("pdf")
    elseif output_format == :png
      GR.inline("png")
    else
      error("unknown output format '$output_format'")
    end

    # Check that all variables exist in data file
    if isempty(args["variable"])
      variables = labels
    else
      for var in args["variable"]
        if !(var in labels)
          error("variable '$var' does not exist in the data file $datafile")
        end
      end
      variables = args["variable"]
    end

    # Create output directory if it does not exist
    mkpath(args["output_directory"])

    # Calculate x and y limits
    xlims = (-1, 1) .* (length_level_0/2 + center_level_0[1])
    ylims = (-1, 1) .* (length_level_0/2 + center_level_0[2])

    verbose && println("| Creating plots...")
    @timeit "plot generation" for (variable_id, label) in enumerate(variables)
      verbose && println("| | Variable $label...")

      # Create plot
      verbose && println("| | | Creating figure...")
      @timeit "create figure" plot(size=(2000,2000), thickness_scaling=1,
                                   aspectratio=:equal, legend=:none, title="$label (t = $time)",
                                   colorbar=true, xlims=xlims, ylims=ylims,
                                   tickfontsize=18, titlefontsize=28)

      # Plot contours
      verbose && println("| | | Plotting contours...")
      @timeit "plot contours" contourf!(xs, ys, node_centered_data[:, :, variable_id],
                                        c=:bluesreds, levels=20)

      # Plot grid lines
      if args["grid_lines"]
        verbose && println("| | | Plotting grid lines...")
        @timeit "plot grid lines" plot!(vertices_x, vertices_y, linecolor=:black,
                                        linewidth=1, grid=false)
      end

      # Determine output file name
      base, _ = splitext(splitdir(datafile)[2])
      output_filename = joinpath(args["output_directory"],
                                 "$(base)_$(label)." * string(output_format))

      # Save file
      @timeit "save plot" savefig(output_filename)
    end
  end

  verbose && println("| done.\n")
  print_timer()
  println()
end


# Convert cell-centered values to node-centered values by averaging over all
# four neighbors and making use of the periodicity of the solution
function cell2node(cell_centered_data::AbstractArray{Float64})
  # Create temporary data structure to make the averaging algorithm as simple
  # as possible (by using a ghost layer)
  tmp = similar(cell_centered_data, size(cell_centered_data) .+ (2, 2, 0))

  # Fill center with original data
  tmp[2:end-1, 2:end-1, :] .= cell_centered_data

  # Fill sides with opposite data (periodic domain)
  # x-direction
  tmp[1,   2:end-1, :] .= cell_centered_data[end, :, :]
  tmp[end, 2:end-1, :] .= cell_centered_data[1,   :, :]
  # y-direction
  tmp[2:end-1, 1,   :] .= cell_centered_data[:, end, :]
  tmp[2:end-1, end, :] .= cell_centered_data[:, 1,   :]
  # Corners
  tmp[1,   1,   :] = cell_centered_data[end, end, :]
  tmp[end, 1,   :] = cell_centered_data[1,   end, :]
  tmp[1,   end, :] = cell_centered_data[end, 1,   :]
  tmp[end, end, :] = cell_centered_data[1,   1,   :]

  # Create output data structure
  resolution_in, _, n_variables = size(cell_centered_data)
  resolution_out = resolution_in + 1
  node_centered_data = Array{Float64}(undef, resolution_out, resolution_out, n_variables)

  # Obtain node-centered value by averaging over neighboring cell-centered values
  for j in 1:resolution_out
    for i in 1:resolution_out
      node_centered_data[i, j, :] = (tmp[i,   j,   :] +
                                     tmp[i+1, j,   :] +
                                     tmp[i,   j+1, :] +
                                     tmp[i+1, j+1, :]) / 4
    end
  end

  return node_centered_data
end


# Interpolate unstructured DG data to structured data (cell-centered)
function unstructured2structured(unstructured_data::AbstractArray{Float64},
                                 normalized_coordinates::AbstractArray{Float64},
                                 levels::AbstractArray{Int}, resolution::Int,
                                 nvisnodes_per_level::AbstractArray{Int})
  # Extract data shape information
  n_nodes_in, _, n_elements, n_variables = size(unstructured_data)

  # Get node coordinates for DG locations on reference element
  nodes_in, _ = gauss_lobatto_nodes_weights(n_nodes_in)

  #=# Calculate node coordinates for structured locations on reference element=#
  #=max_level = length(nvisnodes_per_level) - 1=#
  #=visnodes_per_level = []=#
  #=for l in 0:max_level=#
  #=  n_nodes_out = nvisnodes_per_level[l + 1]=#
  #=  dx = 2 / n_nodes_out=#
  #=  push!(visnodes_per_level, collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out)))=#
  #=end=#

  # Calculate interpolation vandermonde matrices for each level
  max_level = length(nvisnodes_per_level) - 1
  vandermonde_per_level = []
  for l in 0:max_level
    n_nodes_out = nvisnodes_per_level[l + 1]
    dx = 2 / n_nodes_out
    nodes_out = collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out))
    push!(vandermonde_per_level, polynomial_interpolation_matrix(nodes_in, nodes_out))
  end

  # For each element, calculate index position at which to insert data in global data structure
  lower_left_index = element2index(normalized_coordinates, levels, resolution, nvisnodes_per_level)

  # Create output data structure
  structured = Array{Float64}(undef, resolution, resolution, n_variables)

  # For each variable, interpolate element data and store to global data structure
  for v in 1:n_variables
    # Reshape data array for use in interpolate_nodes function
    reshaped_data = reshape(unstructured_data[:, :, :, v], 1, n_nodes_in, n_nodes_in, n_elements)

    for element_id in 1:n_elements
      # Extract level for convenience
      level = levels[element_id]

      # Determine target indices
      n_nodes_out = nvisnodes_per_level[level + 1]
      first = lower_left_index[:, element_id]
      last = first .+ (n_nodes_out - 1)

      # Interpolate data
      vandermonde = vandermonde_per_level[level + 1]
      structured[first[1]:last[1], first[2]:last[2], v] .= (
          reshape(interpolate_nodes(reshaped_data[:, :, :, element_id], vandermonde, 1),
                  n_nodes_out, n_nodes_out))
    end
  end

  return structured
end


# For a given normalized element coordinate, return the index of its lower left
# contribution to the global data structure
function element2index(normalized_coordinates::AbstractArray{Float64}, levels::AbstractArray{Int},
                       resolution::Int, nvisnodes_per_level::AbstractArray{Int})
  n_elements = length(levels)

  # First, determine lower left coordinate for all cells
  dx = 2 / resolution
  lower_left_coordinate = Array{Float64}(undef, ndim, n_elements)
  for element_id in 1:n_elements
    nvisnodes = nvisnodes_per_level[levels[element_id] + 1]
    lower_left_coordinate[1, element_id] = (
        normalized_coordinates[1, element_id] - (nvisnodes - 1)/2 * dx)
    lower_left_coordinate[2, element_id] = (
        normalized_coordinates[2, element_id] - (nvisnodes - 1)/2 * dx)
  end

  # Then, convert coordinate to global index
  indices = coordinate2index(lower_left_coordinate, resolution)

  return indices
end


# Find 2D array index for a 2-tuple of normalized, cell-centered coordinates (i.e., in [-1,1])
function coordinate2index(coordinate, resolution::Integer)
  # Calculate 1D normalized coordinates
  dx = 2/resolution
  mesh_coordinates = collect(range(-1 + dx/2, 1 - dx/2, length=resolution))

  # Find index
  id_x = searchsortedfirst.(Ref(mesh_coordinates), coordinate[1, :], lt=(x,y)->x .< y .- dx/2)
  id_y = searchsortedfirst.(Ref(mesh_coordinates), coordinate[2, :], lt=(x,y)->x .< y .- dx/2)
  return transpose(hcat(id_x, id_y))
end


function interpolate_data(data_in::AbstractArray, n_nodes_in::Integer, n_nodes_out::Integer)
  # Get node coordinates for input and output locations on reference element
  nodes_in, _ = gauss_lobatto_nodes_weights(n_nodes_in)
  dx = 2/n_nodes_out
  #=nodes_out = collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out))=#
  nodes_out = collect(range(-1, 1, length=n_nodes_out))

  # Get interpolation matrix
  vandermonde = polynomial_interpolation_matrix(nodes_in, nodes_out)

  # Create output data structure
  n_elements = div(size(data_in, 1), n_nodes_in^ndim)
  n_variables = size(data_in, 2)
  data_out = Array{eltype(data_in)}(undef, n_nodes_out, n_nodes_out, n_elements, n_variables)

  for n in 1:1
  # Interpolate each variable separately
  for v = 1:n_variables
    # Reshape data to fit expected format for interpolation function
    # FIXME: this "reshape here, reshape later" funny business should be implemented properly
    reshaped = reshape(data_in[:, v], 1, n_nodes_in, n_nodes_in, n_elements)

    # Interpolate data for each cell
    for element_id = 1:1#n_elements
      data_out[:, :, element_id, v] = interpolate_nodes(reshaped[:, :, :, element_id],
                                                        vandermonde, 1)
    end
  end
  end

  return reshape(data_out, n_nodes_out^ndim * n_elements, n_variables)
end


function calc_vtk_points_cells(coordinates::AbstractMatrix{Float64},
                               levels::AbstractVector{Int},
                               center_level_0::AbstractVector{Float64},
                               length_level_0::Float64)
  @assert ndim == 2 "Algorithm currently only works in 2D"

  # Create point locator
  pl = PointLocator(center_level_0, length_level_0, 1e-12)

  # Create arrays for points and cells
  n_elements = length(levels)
  points = Vector{Point}()
  vtk_cells = Vector{MeshCell}(undef, n_elements)
  point_ids = Vector{Int}(undef, 2^ndim)

  # Create VTK cell for each Trixi element
  for element_id in 1:n_elements
    # Get point id for each vertex
    x = coordinates[1, element_id]
    y = coordinates[2, element_id]
    dx = length_level_0 / 2^levels[element_id]
    point_ids[1] = insert!(pl, points, x - dx/2, y - dx/2)
    point_ids[2] = insert!(pl, points, x + dx/2, y - dx/2)
    point_ids[3] = insert!(pl, points, x - dx/2, y + dx/2)
    point_ids[4] = insert!(pl, points, x + dx/2, y + dx/2)

    # Add cell
    vtk_cells[element_id] = MeshCell(VTKCellTypes.VTK_PIXEL, point_ids) 
  end

  # Convert array-of-points to two-dimensional array
  vtk_points = Matrix{Float64}(undef, ndim, length(points))
  for point_id in 1:length(points)
    vtk_points[1, point_id] = points[point_id].x
    vtk_points[2, point_id] = points[point_id].y
  end

  return vtk_points, vtk_cells
end


function calc_vertices(coordinates::AbstractArray{Float64, 2},
                       levels::AbstractArray{Int}, length_level_0::Float64)
  @assert ndim == 2 "Algorithm currently only works in 2D"

  # Initialize output arrays
  n_elements = length(levels)
  x = Array{Float64, 2}(undef, 2^ndim+1, n_elements)
  y = Array{Float64, 2}(undef, 2^ndim+1, n_elements)

  # Calculate vertices for all coordinates at once
  for element_id in 1:n_elements
    length = length_level_0 / 2^levels[element_id]
    x[1, element_id] = coordinates[1, element_id] - 1/2 * length
    x[2, element_id] = coordinates[1, element_id] + 1/2 * length
    x[3, element_id] = coordinates[1, element_id] + 1/2 * length
    x[4, element_id] = coordinates[1, element_id] - 1/2 * length
    x[5, element_id] = coordinates[1, element_id] - 1/2 * length

    y[1, element_id] = coordinates[2, element_id] - 1/2 * length
    y[2, element_id] = coordinates[2, element_id] - 1/2 * length
    y[3, element_id] = coordinates[2, element_id] + 1/2 * length
    y[4, element_id] = coordinates[2, element_id] + 1/2 * length
    y[5, element_id] = coordinates[2, element_id] - 1/2 * length
  end

  return x, y
end


# Use data file to extract mesh filename from attributes
function extract_mesh_filename(filename::String)
  # Open file for reading
  h5open(filename, "r") do file
    # Extract filename relative to data file
    mesh_file = read(attrs(file)["mesh_file"])

    return joinpath(dirname(filename), mesh_file)
  end
end


# Read in mesh file and return relevant data
function read_meshfile(filename::String)
  # Open file for reading
  h5open(filename, "r") do file
    # Extract basic information
    ndim = read(attrs(file)["ndim"])
    n_cells = read(attrs(file)["n_cells"])
    n_leaf_cells = read(attrs(file)["n_leaf_cells"])
    center_level_0 = read(attrs(file)["center_level_0"])
    length_level_0 = read(attrs(file)["length_level_0"])

    # Extract coordinates, levels, child cells
    coordinates = Array{Float64}(undef, ndim, n_cells)
    coordinates .= read(file["coordinates"])
    levels = Array{Int}(undef, n_cells)
    levels .= read(file["levels"])
    child_ids = Array{Int}(undef, n_children_per_cell(ndim), n_cells)
    child_ids .= read(file["child_ids"])

    # Extract leaf cells (= cells to be plotted) and contract all other arrays accordingly
    leaf_cells = similar(levels)
    n_cells = 0
    for cell_id in 1:length(levels)
      if sum(child_ids[:, cell_id]) > 0
        continue
      end

      n_cells += 1
      leaf_cells[n_cells] = cell_id
    end
    leaf_cells = leaf_cells[1:n_cells]

    coordinates = coordinates[:, leaf_cells]
    levels = levels[leaf_cells]

    return center_level_0, length_level_0, leaf_cells, coordinates, levels
  end
end


function read_datafile(filename::String)
  # Open file for reading
  h5open(filename, "r") do file
    # Extract basic information
    N = read(attrs(file)["N"])
    n_elements = read(attrs(file)["n_elements"])
    n_variables = read(attrs(file)["n_vars"])
    time = read(attrs(file)["time"])

    # Extract labels for legend
    labels = Array{String}(undef, 1, n_variables)
    for v = 1:n_variables
      labels[1, v] = read(attrs(file["variables_$v"])["name"])
    end

    # Extract data arrays
    n_nodes = N + 1
    data = Array{Float64}(undef, n_nodes, n_nodes, n_elements, n_variables)
    for v = 1:n_variables
      vardata = read(file["variables_$v"])
      #=@show minimum(vardata), maximum(vardata)=#
      @views data[:, :, :, v][:] .= vardata
    end

    return labels, data, n_nodes, time
  end
end


function get_output_format(format::String)
  if format == "png"
    return :png
  elseif format == "pdf"
    return :pdf
  else
    error("unrecognized output file format '$format' (must be 'png' or 'pdf')")
  end
end


function parse_commandline_arguments(args=ARGS)
  # If anything is changed here, it should also be checked at the beginning of run()
  # FIXME: Refactor the code to avoid this redundancy
  s = ArgParseSettings()
  @add_arg_table s begin
    "datafile"
      help = "Name of Trixi solution/restart/grid file to convert to a VTK XML file."
      arg_type = String
      required = true
      nargs = '+'
    "--verbose", "-v"
      help = "Enable verbose output to avoid despair over long plot times 😉"
      action = :store_true
    "--output-directory", "-o"
      help = "Output directory where generated images are stored"
      dest_name = "output_directory"
      arg_type = String
      default = "."
    "--nvisnodes"
      help = ("Number of visualization nodes per cell "
              * "(default: four times the number of DG nodes). "
              * "A value of zero prevents any interpolation of data.")
      arg_type = Int
      default = nothing
  end

  return parse_args(s)
end


####################################################################################################
# Submodule with point locator functionality
####################################################################################################
module PointLocators


# Point structure
Point = NamedTuple{(:x, :y), Tuple{Float64, Float64}}


# Main data structure for quadtree-like point locator
struct PointLocator
  center::Point
  length::Float64
  max_point_ids::Int
  point_ids::Vector{Int}
  children::Vector{PointLocator}

 function PointLocator(center, length, offset=0.0)
   # Use offset to avoid ambiguitites for points falling on coordinate lines
   center_ .= center .+ offset
   length_ = length + 2 * offset

   # Use at most 20 points per locator node
   max_point_ids = 20
   point_ids = Vector{Int}()
   children = Vector{PointLocator}()

   return PointLocator(center_, length_, max_point_ids, point_ids, children)
 end
end


# Return if locator has no children
is_leaf(pl::PointLocator) = isempty(p.children)


# Insert point into locator
function insert!(pl::PointLocator, points::Vector{Point}, point::Point)
  # Check if locator is leaf
  if is_leaf(pl)
    # If locator is leaf, check if point already exists
    point_id = get_point_id(pl, point)

    # Return point_id if found
    if point_id > 0
      return point_id
    end

    # Otherwise check if there is enough room in current locator or if it needs to be refined
    if length(pl.point_ids) < pl.max_point_ids
      # Add point to this locator and to list of points
      point_id = length(points) + 1
      push!(points, point)
      push!(point_ids, point_id)
      return point_id
    else
      # Refine locator
      refine!(pl)

      # Re-add to newly refined locator
      insert!(pl, points, point)
    end
  else
    # If locator is non-lef, find appropriate child locator and add point there
    child_locator = pl.children[get_child_id(pl, point)]
    insert!(child_locator, points, point)
  end
end
insert!(pl::PointLocator, pts::Vector{Point}, x::Float64, y::Float64) = insert!(pl, pts, (x, y))


# Refine point locator and move points to child locators
function refine!(pl::PointLocator)
  # Store for convenience
  dx = pl.length / 2
  x = pl.center.x
  y = pl.center.y

  # Add lower left child
  push!(pl.children, PointLocator((x - dx/2, y - dx/2), dx))

  # Add lower right child
  push!(pl.children, PointLocator((x + dx/2, y - dx/2), dx))

  # Add upper left child
  push!(pl.children, PointLocator((x - dx/2, y + dx/2), dx))

  # Add upper right child
  push!(pl.children, PointLocator((x + dx/2, y + dx/2), dx))
end


# Get id of child locator for given point
function get_child_id(pl::PointLocator, point::Point)
  if point.y < pl.center.y
    if point.x < pl.center.x
      # Lower left child
      return 1
    else
      # Lower right child
      return 2
    end
  else
    if point.x < pl.center.x
      # Upper left child
      return 3
    else
      # Upper right child
      return 4
    end
  end
end


# Get point id if point exists or zero otherwise
function get_point_id(pl::PointLocator, points::Vector{Point}, point::Point)
  # Iterate over point ids, extract point coordinates and compare to point
  for point_id in pl.point_ids
    x = points[point_id].x
    y = points[point_id].y
    if isapprox(point.x, x, atol=1e-13) && isapprox(point.y, y, atol=1e-13)
      return point_id
    end
  end

  # If no point was found, return zero
  return 0
end


end



####################################################################################################
# From auxiliary/auxiliary.jl
####################################################################################################
# Allow an expression to be terminated gracefully by Ctrl-c.
#
# On Unix-like operating systems, gracefully handle user interrupts (SIGINT), also known as
# Ctrl-c, while evaluation expression `ex`.
macro interruptable(ex)
  @static Sys.isunix() && quote
    ccall(:jl_exit_on_sigint, Cvoid, (Cint,), 0)

    try
      # Try to run code
      $(esc(ex))
    catch e
      # Only catch interrupt exceptions and end with a nice message
      isa(e, InterruptException) || rethrow(e)
      println(stderr, "\nExecution interrupted by user (Ctrl-c)")
    end

    # Disable interrupt handling again
    ccall(:jl_exit_on_sigint, Cvoid, (Cint,), 1)
  end
end



####################################################################################################
# From mesh/trees.jl
####################################################################################################
# Auxiliary methods for often-required calculations
# Number of potential child cells
n_children_per_cell() = n_children_per_cell(ndim)
n_children_per_cell(dims::Integer) = 2^dims

end # module Trixi2Vtu


if (abspath(PROGRAM_FILE) == @__FILE__) || (@isdefined(run_script) && run_script)
  #=@Trixi2Vtu.interruptable Trixi2Vtu.run()=#
  Trixi2Vtu.run(args=ARGS)
end
