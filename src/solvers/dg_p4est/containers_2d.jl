# Initialize data structures in element container
function init_elements!(elements, mesh::P4estMesh{2}, basis::LobattoLegendreBasis)
  @unpack node_coordinates, jacobian_matrix,
          contravariant_vectors, inverse_jacobian = elements

  calc_node_coordinates!(node_coordinates, mesh, basis)

  for element in 1:ncells(mesh)
    calc_jacobian_matrix!(jacobian_matrix, element, node_coordinates, basis)

    calc_contravariant_vectors!(contravariant_vectors, element, jacobian_matrix)

    calc_inverse_jacobian!(inverse_jacobian, element, jacobian_matrix)
  end

  return nothing
end


# Interpolate tree_node_coordinates to each quadrant
function calc_node_coordinates!(node_coordinates,
                                mesh::P4estMesh{2},
                                basis::LobattoLegendreBasis)
  # Hanging nodes will cause holes in the mesh if its polydeg is higher
  # than the polydeg of the solver.
  @assert length(basis.nodes) >= length(mesh.nodes) "The solver can't have a lower polydeg than the mesh"

  # We use `StrideArray`s here since these buffers are used in performance-critical
  # places and the additional information passed to the compiler makes them faster
  # than native `Array`s.
  tmp1    = StrideArray(undef, real(mesh),
                        StaticInt(2), static_length(basis.nodes), static_length(mesh.nodes))
  matrix1 = StrideArray(undef, real(mesh),
                        static_length(basis.nodes), static_length(mesh.nodes))
  matrix2 = similar(matrix1)
  baryweights_in = barycentric_weights(mesh.nodes)

  # Macros from p4est
  p4est_root_len = 1 << P4EST_MAXLEVEL
  p4est_quadrant_len(l) = 1 << (P4EST_MAXLEVEL - l)

  trees = unsafe_wrap_sc(p4est_tree_t, mesh.p4est.trees)

  for tree in eachindex(trees)
    offset = trees[tree].quadrants_offset
    quadrants = unsafe_wrap_sc(p4est_quadrant_t, trees[tree].quadrants)

    for i in eachindex(quadrants)
      element = offset + i
      quad = quadrants[i]

      quad_length = p4est_quadrant_len(quad.level) / p4est_root_len

      nodes_out_x = 2 * (quad_length * 1/2 * (basis.nodes .+ 1) .+ quad.x / p4est_root_len) .- 1
      nodes_out_y = 2 * (quad_length * 1/2 * (basis.nodes .+ 1) .+ quad.y / p4est_root_len) .- 1
      polynomial_interpolation_matrix!(matrix1, mesh.nodes, nodes_out_x, baryweights_in)
      polynomial_interpolation_matrix!(matrix2, mesh.nodes, nodes_out_y, baryweights_in)

      multiply_dimensionwise!(
        view(node_coordinates, :, :, :, element),
        matrix1, matrix2,
        view(mesh.tree_node_coordinates, :, :, :, tree),
        tmp1
      )
    end
  end

  return node_coordinates
end


function init_surfaces!(interfaces, mortars, boundaries, mesh::P4estMesh{2})
  # Let p4est iterate over all interfaces and call init_surfaces_iter_face
  iter_face_c = @cfunction(init_surfaces_iter_face,
                           Cvoid, (Ptr{p4est_iter_face_info_t}, Ptr{Cvoid}))
  user_data = InitSurfacesIterFaceUserData(
    interfaces, mortars, boundaries, mesh)

  iterate_p4est(mesh.p4est, user_data; iter_face_c=iter_face_c)

  return interfaces
end


@inline function init_interface_node_indices!(interfaces::InterfaceContainerP4est{2},
                                              faces, orientation, interface_id)
  # Iterate over primary and secondary element
  for side in 1:2
    # Align interface in positive coordinate direction of primary element.
    # For orientation == 1, the secondary element needs to be indexed backwards
    # relative to the interface.
    if side == 1 || orientation == 0
      # Forward indexing
      i = :i
    else
      # Backward indexing
      i = :i_backwards
    end

    if faces[side] == 0
      # Index face in negative x-direction
      interfaces.node_indices[side, interface_id] = (:one, i)
    elseif faces[side] == 1
      # Index face in positive x-direction
      interfaces.node_indices[side, interface_id] = (:end, i)
    elseif faces[side] == 2
      # Index face in negative y-direction
      interfaces.node_indices[side, interface_id] = (i, :one)
    else # faces[side] == 3
      # Index face in positive y-direction
      interfaces.node_indices[side, interface_id] = (i, :end)
    end
  end

  return interfaces
end


@inline function init_boundary_node_indices!(boundaries::BoundaryContainerP4est{2},
                                             face, boundary_id)
  if face == 0
    # Index face in negative x-direction
    boundaries.node_indices[boundary_id] = (:one, :i)
  elseif face == 1
    # Index face in positive x-direction
    boundaries.node_indices[boundary_id] = (:end, :i)
  elseif face == 2
    # Index face in negative y-direction
    boundaries.node_indices[boundary_id] = (:i, :one)
  else # face == 3
    # Index face in positive y-direction
    boundaries.node_indices[boundary_id] = (:i, :end)
  end

  return boundaries
end


# faces[1] is expected to be the face of the small side.
@inline function init_mortar_node_indices!(mortars::MortarContainerP4est{2},
  faces, orientation, mortar_id)
  for side in 1:2
    # Align mortar in positive coordinate direction of small side.
    # For orientation == 1, the large side needs to be indexed backwards
    # relative to the mortar.
    if side == 1 || orientation == 0
      # Forward indexing for small side or orientation == 0
      i = :i
    else
      # Backward indexing for large side with reversed orientation
      i = :i_backwards
    end

    if faces[side] == 0
      # Index face in negative x-direction
      mortars.node_indices[side, mortar_id] = (:one, i)
    elseif faces[side] == 1
      # Index face in positive x-direction
      mortars.node_indices[side, mortar_id] = (:end, i)
    elseif faces[side] == 2
      # Index face in negative y-direction
      mortars.node_indices[side, mortar_id] = (i, :one)
    else # faces[side] == 3
      # Index face in positive y-direction
      mortars.node_indices[side, mortar_id] = (i, :end)
    end
  end

  return mortars
end


function count_required_surfaces(mesh::P4estMesh{2})
  # Let p4est iterate over all interfaces and call count_surfaces_iter_face
  iter_face_c = @cfunction(count_surfaces_iter_face, Cvoid, (Ptr{p4est_iter_face_info_t}, Ptr{Cvoid}))

  # interfaces, mortars, boundaries
  user_data = [0, 0, 0]

  iterate_p4est(mesh.p4est, user_data; iter_face_c=iter_face_c)

  # Return counters
  return (interfaces = user_data[1],
          mortars    = user_data[2],
          boundaries = user_data[3])
end
