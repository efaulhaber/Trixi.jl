# Note: This is an experimental feature and may be changed in future releases without notice.
mutable struct StructuredMesh{NDIMS, RealT<:Real} <: AbstractMesh{NDIMS}
  cells_per_dimension::NTuple{NDIMS, Int}
  faces::Vector{Function}
  current_filename::String
  unsaved_changes::Bool
end

function StructuredMesh(cells_per_dimension, faces, RealT)
  NDIMS = length(cells_per_dimension)

  return StructuredMesh{NDIMS, RealT}(cells_per_dimension, faces, "", true)
end


function bilinear_mapping(x, y, mesh)
  @unpack faces = mesh

  x1 = faces[1](-1) # Bottom left
  @assert x1 ≈ faces[3](-1) "faces[1](-1) needs to match faces[3](-1) (bottom left corner)"
  x2 = faces[2](-1) # Bottom right
  @assert x2 ≈ faces[3](1) "faces[2](-1) needs to match faces[3](1) (bottom right corner)"
  x3 = faces[1](1) # Top left
  @assert x3 ≈ faces[4](-1) "faces[1](1) needs to match faces[4](-1) (top left corner)"
  x4 = faces[2](1) # Top right
  @assert x4 ≈ faces[4](1) "faces[2](1) needs to match faces[4](1) (top right corner)"

  return 0.25 * (x1 * (1 - x) * (1 - y) +
                 x2 * (1 + x) * (1 - y) +
                 x3 * (1 - x) * (1 + y) +
                 x4 * (1 + x) * (1 + y))
end


function transfinite_mapping(x, y, mesh)
  @unpack faces = mesh

  linear_interpolation_x(x, y) = 0.5 * (faces[1](y) * (1 - x) + faces[2](y) * (1 + x))
  linear_interpolation_y(x, y) = 0.5 * (faces[3](x) * (1 - y) + faces[4](x) * (1 + y))

  return linear_interpolation_x(x, y) + linear_interpolation_y(x, y) - bilinear_mapping(x, y, mesh)
end


@inline Base.ndims(::StructuredMesh{NDIMS}) where {NDIMS} = NDIMS
Base.size(mesh::StructuredMesh) = mesh.cells_per_dimension
Base.size(mesh::StructuredMesh, i) = mesh.cells_per_dimension[i]

function Base.show(io::IO, ::StructuredMesh{NDIMS, RealT}) where {NDIMS, RealT}
  print(io, "StructuredMesh{", NDIMS, ", ", RealT, "}")
end

function Base.show(io::IO, ::MIME"text/plain", mesh::StructuredMesh{NDIMS, RealT}) where {NDIMS, RealT}
  if get(io, :compact, false)
    show(io, mesh)
  else
    setup = [
            "size" => size(mesh),
            "faces" => mesh.faces
            ]
    summary_box(io, "StructuredMesh{" * string(NDIMS) * ", " * string(RealT) * "}", setup)
  end
end
